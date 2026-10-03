defmodule HandbeamProbe.NativeChat do
  @moduledoc "Native chat intent and projection; Handbeam still owns runs and transcripts."

  use Gettext, backend: HandbeamProbe.Gettext
  alias Handbeam.Agent.{Coordinator, ModelConfig, PendingMessages, Reasoning, ThinkingFilter}
  alias Handbeam.PubSub.{AgentEvent, Projection, Session}
  alias Handbeam.WorkspaceStore
  alias HandbeamProbe.Bridge.Payload
  alias HandbeamProbe.NativeLocalImage

  @reload_coalesce_ms 80

  def reload_coalesce_ms, do: @reload_coalesce_ms

  def load(conversation, opts \\ []) do
    id = conversation["id"]
    snapshot = Keyword.get_lazy(opts, :snapshot, fn -> Projection.snapshot(id) end)
    events = Enum.sort_by(Map.get(snapshot, :control_events, snapshot.events), & &1.seq)
    {workspace_id, workspace_path} = bind_workspace(conversation)
    page = Keyword.get_lazy(opts, :history_page, fn -> history_page(id, 100) end)
    history_loaded? = is_map(page)
    page = page || %{entries: [], before: nil, has_more?: false}

    state = %{
      conversation: conversation,
      workspace_id: workspace_id,
      workspace_path: workspace_path,
      entries: NativeLocalImage.resolve_entries(page.entries, workspace_path, id),
      history_before: page.before,
      history_has_more?: page.has_more?,
      history_loaded?: history_loaded?,
      running: running?(id),
      stream: "",
      thinking: false,
      thinking_buffer: "",
      pending_approval: nil,
      approval_seq: nil,
      pending: PendingMessages.new(),
      seq: 0,
      epoch: nil,
      last_transcript_reload_at: nil,
      transcript_dirty: not history_loaded?,
      reload_timer: nil,
      stream_since_boundary: ""
    }

    # Text is durable before broadcast. Restore only the active run's control
    # state; replaying text over a history read would duplicate the reply.
    active_events =
      Enum.filter(events, &(event_payload(&1.payload)["run_id"] == snapshot.meta[:run_id]))

    state = if state.running, do: Enum.reduce(active_events, state, &approval/2), else: state
    latest_event = Enum.max_by(snapshot.events, & &1.seq, fn -> nil end)

    %{
      state
      | seq: if(history_loaded?, do: snapshot.last_seq, else: 0),
        epoch: if(history_loaded?, do: Map.get(snapshot, :epoch)),
        thinking:
          state.running and match?(%{kind: :thinking_delta}, latest_event) and
            event_payload(latest_event.payload)["run_id"] == snapshot.meta[:run_id]
    }
    |> reconcile_pending()
  end

  def project(event, state, opts \\ [])

  # History can open while Session is absent. The first stamped event must
  # establish a real checkpoint and restore controls, not just adopt its epoch.
  def project(
        %{topic: "session:" <> id, epoch: epoch},
        %{conversation: %{"id" => id}, epoch: nil} = state,
        _opts
      )
      when is_binary(epoch),
      do: recover(state)

  def project(
        %{topic: "session:" <> id},
        %{conversation: %{"id" => id}, history_loaded?: false} = state,
        _opts
      ),
      do: recover(state)

  def project(event, state, opts) do
    case Projection.classify(
           event,
           Session.session_topic(state.conversation["id"]),
           state.seq,
           state.epoch
         ) do
      :apply ->
        payload = event_payload(event.payload)

        if event.kind == :message_delta and Map.has_key?(payload, "transcript_id") and
             Projection.text_patch(state.entries, payload) == :recover do
          recover(state)
        else
          state =
            event
            |> then(&approval(&1, %{state | seq: event.seq, epoch: event.epoch || state.epoch}))
            |> pending_event(event)

          if event.kind in [:message_delta, :thinking_delta],
            do: delta(event, state),
            else: project_boundary(event, state, opts)
        end

      :recover ->
        recover(state)

      :ignore ->
        state
    end
  end

  def apply_deferred_reload(state, opts \\ []) do
    now = now(opts)
    id = state.conversation["id"]

    %{
      state
      | entries: load_entries(state, opts),
        last_transcript_reload_at: now,
        transcript_dirty: false,
        reload_timer: nil,
        stream: state.stream_since_boundary,
        stream_since_boundary: "",
        thinking: false,
        thinking_buffer: "",
        running: state.pending_approval != nil or running?(id)
    }
    |> reconcile_pending()
  end

  def send_message(workspace, conversation, content, attachments \\ [], opts \\ []) do
    free? = Handbeam.ConversationStore.free?(conversation)
    {settings, model, models, resolve} = model_binding(workspace, free?)
    inbound_id = Keyword.get(opts, :inbound_id) || Ecto.UUID.generate()
    deliver_as = Keyword.get(opts, :deliver_as, :steer)
    entry = Enum.find(models, &(&1.id == model))

    with true <- is_binary(model),
         {:ok, config, model_id} <- resolve.(model),
         :ok <-
           Handbeam.Agent.ModelCapabilities.validate_inputs(
             entry,
             HandbeamProbe.NativeModelInputs.required_inputs(attachments)
           ),
         {:ok, review_opts} <- review_run_opts(conversation["id"], opts),
         {:ok, message, persistable} <-
           build_message(content, attachments, conversation, workspace, free?) do
      config = Reasoning.apply_provider_options(config, entry, settings.reasoning)
      runtime_opts = Handbeam.Settings.ModelAISettings.to_runtime_opts(settings)
      message = put_inbound_message_id(message, inbound_id)

      case Coordinator.add_message(
             conversation["id"],
             message,
             Keyword.merge(
               runtime_opts,
               Keyword.merge(
                 coordinator_opts(
                   free?,
                   workspace,
                   config,
                   model_id,
                   deliver_as,
                   inbound_id,
                   persistable
                 ),
                 review_opts
               )
             )
           ) do
        {:ok, ack} ->
          {:ok,
           ack
           |> Map.put(:inbound_id, inbound_id)
           |> Map.put(:deliver_as, deliver_as)
           |> Map.put(:attachments, persistable)
           |> Map.put(:content, content)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :empty} -> {:error, gettext("Please enter a message")}
      false -> {:error, gettext("Add a model in Settings first")}
      {:error, :run_in_progress} -> {:error, :run_in_progress}
      {:error, _} = error -> error
    end
  end

  defp model_binding(_workspace, true) do
    settings = Handbeam.Settings.global_model_ai()
    models = ModelConfig.all_global_models()

    model =
      if settings.default_model && Enum.any?(models, &(&1.id == settings.default_model)),
        do: settings.default_model,
        else: models |> List.first() |> then(&if(&1, do: &1.id))

    {settings, model, models, &resolve_global_model/1}
  end

  defp model_binding(workspace, false) do
    path = workspace["path"]
    settings = Handbeam.Settings.effective_model_ai(path)
    models = ModelConfig.available_models_for_workspace(path)
    model = settings.default_model || ModelConfig.default_model_for_workspace(path)
    {settings, model, models, &ModelConfig.resolve_model_for_workspace(path, &1)}
  end

  defp resolve_global_model(composite_id) do
    case Enum.find(ModelConfig.all_global_models(), &(&1.id == composite_id)) do
      %{provider_id: provider_id, model_id: model_id} = _entry ->
        case ModelConfig.provider_config_for(File.cwd!(), provider_id, model_id) do
          {:ok, config} -> {:ok, config, model_id}
          {:error, _} = error -> error
        end

      _ ->
        {:error, "Model #{composite_id} is not in the global catalog"}
    end
  end

  defp build_message(content, attachments, conversation, _workspace, true) do
    Handbeam.Attachments.MessageBuilder.build(content, attachments,
      chat_scope: :free,
      conversation_id: conversation["id"],
      staging_roots: Application.get_env(:handbeam_probe, :staging_roots, [])
    )
  end

  defp build_message(content, attachments, conversation, workspace, false) do
    Handbeam.Attachments.MessageBuilder.build(content, attachments,
      workspace_path: workspace["path"],
      conversation_id: conversation["id"],
      staging_roots: Application.get_env(:handbeam_probe, :staging_roots, [])
    )
  end

  defp coordinator_opts(true, _workspace, config, model_id, deliver_as, inbound_id, persistable) do
    [
      chat_scope: :free,
      provider_config: config,
      model: model_id,
      tools: Handbeam.Agent.free_chat_tools(),
      workspace_id: nil,
      source: :native,
      streaming: true,
      deliver_as: deliver_as,
      inbound_id: inbound_id,
      transcript_id: inbound_id,
      message_id: inbound_id,
      attachments: persistable
    ]
  end

  defp coordinator_opts(false, workspace, config, model_id, deliver_as, inbound_id, persistable) do
    [
      chat_scope: :workspace,
      provider_config: config,
      model: model_id,
      tools: Handbeam.Agent.default_tools(),
      workspace_id: workspace["id"],
      workspace_path: workspace["path"],
      source: :native,
      streaming: true,
      deliver_as: deliver_as,
      inbound_id: inbound_id,
      transcript_id: inbound_id,
      message_id: inbound_id,
      attachments: persistable
    ]
  end

  defp review_run_opts(conversation_id, opts) do
    if Keyword.get(opts, :composer_mode, :chat) == :review do
      case Coordinator.status(conversation_id) do
        {:ok, %{running?: true}} ->
          {:error, :run_in_progress}

        _idle ->
          case HandbeamProbe.WritingPhotoReviews.load_instructions() do
            {:ok, body} -> {:ok, [task_instructions: body]}
            {:error, reason} -> {:error, reason}
          end
      end
    else
      {:ok, []}
    end
  end

  def transcript(id) do
    case Handbeam.ConversationTranscriptStore.list(id) do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end

  def load_older(state) do
    id = state.conversation["id"]

    case Handbeam.ConversationTranscriptStore.page(id, limit: 100, before: state.history_before) do
      {:ok, page} ->
        entries =
          (page.entries ++ state.entries)
          |> Enum.reverse()
          |> Enum.uniq_by(& &1["id"])
          |> Enum.reverse()

        %{
          state
          | entries: NativeLocalImage.resolve_entries(entries, state.workspace_path, id),
            history_before: page.before,
            history_has_more?: page.has_more?,
            history_loaded?: true
        }
        |> reconcile_pending()

      {:error, :invalid_cursor} ->
        recover(state)

      {:error, _} ->
        state
    end
  end

  defp history_page(id, count) do
    case Projection.history(id, count) do
      {:ok, page} -> page
      {:error, _} -> nil
    end
  end

  defp recover(state) do
    case Projection.recover(state.conversation["id"], length(state.entries)) do
      {:ok, %{snapshot: snapshot, history: history}} ->
        recovered = load(state.conversation, snapshot: snapshot, history_page: history)
        last_seq = if state.epoch == snapshot.epoch, do: state.seq, else: 0
        pending = PendingMessages.replay(state.pending, snapshot.control_events, last_seq)
        %{recovered | pending: Map.merge(pending, recovered.pending)} |> reconcile_pending()

      {:error, _} ->
        state
    end
  end

  def open_tool_action(conversation_id, :browser, id) do
    if Handbeam.Browser.WebViewSession.snapshot_state(id).conversation_id == conversation_id,
      do: Handbeam.Browser.WebViewSession.user_takeover(id),
      else: {:error, :wrong_conversation}
  catch
    :exit, _ -> {:error, :session_unavailable}
  end

  def open_tool_action(conversation_id, :preview, id) do
    with {:ok, record} <- Handbeam.Preview.fetch_open(id),
         true <- record.conversation_id == conversation_id do
      url = Handbeam.Preview.shell_url(id, HandbeamWeb.Endpoint.url())
      meta = %{conversation_id: conversation_id, preview_id: id, url: url, client: :overlay}

      with :ok <- Handbeam.Browser.Display.show(:preview, id, meta) do
        case Handbeam.NativeDisplay.command(%{
               op: :show,
               owner: :preview,
               id: id,
               url: url,
               conversation_id: conversation_id,
               generation: 1
             }) do
          {:error, _} = error ->
            Handbeam.Browser.Display.hide(:preview, id)
            error

          _ ->
            :ok
        end
      end
    else
      false -> {:error, :wrong_conversation}
      error -> error
    end
  end

  defp bind_workspace(%{"workspace_id" => workspace_id}) when is_binary(workspace_id) do
    case WorkspaceStore.get(workspace_id) do
      {:ok, workspace} -> {workspace["id"], workspace["path"]}
      _ -> {workspace_id, nil}
    end
  end

  defp bind_workspace(_), do: {nil, nil}

  defp put_inbound_message_id(%Handbeam.Agent.Message{} = message, id), do: %{message | id: id}
  defp put_inbound_message_id(content, _id), do: content

  defp pending_event(state, %{kind: :candidate_message_injected, payload: payload}) do
    %{state | pending: PendingMessages.apply_injected(state.pending, event_payload(payload))}
  end

  defp pending_event(state, %{kind: :candidate_message_deleted, payload: payload}) do
    %{state | pending: PendingMessages.apply_deleted(state.pending, event_payload(payload))}
  end

  defp pending_event(state, %{kind: :run_end, payload: payload}) do
    status = event_payload(payload)["status"]
    %{state | pending: PendingMessages.apply_run_end(state.pending, status)}
  end

  defp pending_event(state, _event), do: state

  defp reconcile_pending(state) do
    id = state.conversation["id"]
    pending = Map.get(state, :pending) || PendingMessages.new()

    %{
      state
      | pending:
          PendingMessages.reconcile(pending, session_pending(id), state.running, state.entries)
    }
  end

  defp session_pending(id) do
    if Session.whereis(id) do
      Session.get_pending_messages(id)
    else
      []
    end
  catch
    :exit, _ -> []
  end

  def note_enqueued(state, id, deliver_as, extra \\ %{}) when is_binary(id) do
    %{state | pending: PendingMessages.put_queued(state.pending, id, deliver_as, extra)}
  end

  def drop_pending(state, id) when is_binary(id) do
    %{state | pending: PendingMessages.drop(state.pending, id)}
  end

  def drop_transcript_entry(conversation_id, id)
      when is_binary(conversation_id) and is_binary(id) do
    case Handbeam.ConversationTranscriptStore.list(conversation_id) do
      {:ok, entries} ->
        Handbeam.ConversationTranscriptStore.replace_all(
          conversation_id,
          Enum.reject(entries, &(Map.get(&1, "id") == id))
        )

      error ->
        error
    end
  end

  defp running?(id) do
    match?({:ok, %{running?: true}}, Coordinator.status(id))
  end

  defp still_running?(%{kind: :run_end, payload: payload}, state, _id) do
    status = event_payload(payload)["status"]

    cond do
      AgentEvent.terminal_status?(status) -> false
      AgentEvent.waiting_status?(status) -> true
      true -> state.running
    end
  end

  defp still_running?(_event, state, id) do
    state.pending_approval != nil or running?(id)
  end

  defp project_boundary(event, state, opts) do
    now = now(opts)
    id = state.conversation["id"]

    running = still_running?(event, state, id)

    if leading_reload?(state.last_transcript_reload_at, now) do
      %{
        state
        | entries: load_entries(state, opts),
          last_transcript_reload_at: now,
          transcript_dirty: false,
          stream: "",
          stream_since_boundary: "",
          thinking: false,
          thinking_buffer: "",
          running: running
      }
    else
      %{
        state
        | transcript_dirty: true,
          stream_since_boundary: "",
          running: running
      }
    end
  end

  defp leading_reload?(nil, _now), do: true

  defp leading_reload?(last_at, now), do: now - last_at >= @reload_coalesce_ms

  defp now(opts), do: Keyword.get_lazy(opts, :now, fn -> System.monotonic_time(:millisecond) end)

  @doc "Re-read the transcript with sent-image paths resolved (post-send refresh)."
  def reload_entries(state), do: load_entries(state, [])

  defp load_entries(state, opts) do
    id = state.conversation["id"]

    id
    |> read_transcript(opts, state.entries)
    |> NativeLocalImage.resolve_entries(Map.get(state, :workspace_path), id)
  end

  defp read_transcript(id, opts, existing) do
    case Keyword.get(opts, :transcript) do
      fun when is_function(fun, 1) ->
        fun.(id)

      _ ->
        case Projection.history(id, length(existing)) do
          {:ok, page} -> page.entries
          {:error, _} -> existing
        end
    end
  end

  defp approval(%{kind: :tool_approval_requested, payload: payload, seq: seq}, state),
    do: %{state | pending_approval: event_payload(payload), approval_seq: seq}

  defp approval(%{kind: :run_end, payload: payload}, state) do
    if AgentEvent.terminal_status?(event_payload(payload)["status"]),
      do: %{state | pending_approval: nil, approval_seq: nil},
      else: state
  end

  defp approval(%{kind: kind}, state)
       when kind in [
              :run_start,
              :run_resumed,
              :turn_start,
              :tool_start,
              :tool_end,
              :message_delta
            ] do
    %{state | pending_approval: nil, approval_seq: nil}
  end

  defp approval(_, state), do: state

  @doc """
  Single decode point for Session event payloads read by the native UI.

  Live `Handbeam.PubSub.Session` events carry atom keys; events restored from
  `Handbeam.SessionStore.File` carry the JSON string keys. Every map key is
  stringified (recursively) so consumers read one shape (`"action_requests"`,
  `"tool_call_id"`, …) and never fall back between the two.
  """
  @spec event_payload(term()) :: term()
  def event_payload(payload), do: Payload.string_keys(payload)

  defp delta(%{kind: :message_delta, payload: payload}, state) do
    payload = event_payload(payload)

    if Map.has_key?(payload, "transcript_id") do
      case Projection.text_patch(state.entries, payload) do
        {:ok, entry} ->
          entries =
            if Enum.any?(state.entries, &(&1["id"] == entry["id"])),
              do: Enum.map(state.entries, &if(&1["id"] == entry["id"], do: entry, else: &1)),
              else: state.entries ++ [entry]

          %{state | entries: entries, stream: "", thinking: false}

        :ignore ->
          state

        :recover ->
          recover(state)
      end
    else
      legacy_delta(payload["chunk"] || "", state)
    end
  end

  defp delta(%{kind: :thinking_delta}, state), do: %{state | thinking: true}

  defp legacy_delta(chunk, state) do
    {thinking, text, buffer} = ThinkingFilter.strip(state.thinking_buffer, chunk)

    stream_since_boundary =
      if state.transcript_dirty,
        do: state.stream_since_boundary <> text,
        else: state.stream_since_boundary

    %{
      state
      | stream: state.stream <> text,
        stream_since_boundary: stream_since_boundary,
        thinking_buffer: buffer,
        thinking: text == "" and (thinking != "" or state.thinking)
    }
  end
end

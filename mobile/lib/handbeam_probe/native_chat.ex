defmodule HandbeamProbe.NativeChat do
  @moduledoc "Native chat intent and projection; Handbeam still owns runs and transcripts."

  use Gettext, backend: HandbeamProbe.Gettext
  alias Handbeam.Agent.{Coordinator, ModelConfig, PendingMessages, Reasoning, ThinkingFilter}
  alias Handbeam.PubSub.Session
  alias Handbeam.WorkspaceStore
  alias HandbeamProbe.Bridge.Payload
  alias HandbeamProbe.NativeLocalImage

  @reload_coalesce_ms 80

  def reload_coalesce_ms, do: @reload_coalesce_ms

  def load(conversation) do
    id = conversation["id"]
    snapshot = if Session.whereis(id), do: safe_snapshot(id), else: %{events: []}
    events = Enum.sort_by(snapshot.events, & &1.seq)
    {workspace_id, workspace_path} = bind_workspace(conversation)

    state = %{
      conversation: conversation,
      workspace_id: workspace_id,
      workspace_path: workspace_path,
      entries: NativeLocalImage.resolve_entries(transcript(id), workspace_path, id),
      running: running?(id),
      stream: "",
      thinking: false,
      thinking_buffer: "",
      pending_approval: nil,
      approval_seq: nil,
      pending: PendingMessages.new(),
      seq: 0,
      last_transcript_reload_at: nil,
      transcript_dirty: false,
      reload_timer: nil,
      stream_since_boundary: ""
    }

    # TranscriptPersistence flushes at every non-delta boundary. Only the
    # trailing, not-yet-persisted deltas belong in the native streaming row.
    tail =
      Enum.reverse(events)
      |> Enum.take_while(&(&1.kind in [:message_delta, :thinking_delta]))
      |> Enum.reverse()

    state = if state.running, do: Enum.reduce(tail, state, &delta/2), else: state

    # The approval event precedes Runner receiving its Task result. Replay while
    # the run is active too, so switching at that boundary cannot lose the review.
    state = if state.running, do: Enum.reduce(events, state, &approval/2), else: state

    %{state | seq: events |> List.last() |> then(&if(&1, do: &1.seq, else: 0))}
    |> reconcile_pending()
  end

  def project(event, state, opts \\ []) do
    if event.topic == Session.session_topic(state.conversation["id"]) and event.seq > state.seq do
      state =
        event
        |> then(&approval(&1, %{state | seq: event.seq}))
        |> pending_event(event)

      if event.kind in [:message_delta, :thinking_delta] do
        delta(event, state)
      else
        project_boundary(event, state, opts)
      end
    else
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
    path = workspace["path"]
    settings = Handbeam.Settings.effective_model_ai(path)
    model = settings.default_model || ModelConfig.default_model_for_workspace(path)
    inbound_id = Keyword.get(opts, :inbound_id) || Ecto.UUID.generate()
    deliver_as = Keyword.get(opts, :deliver_as, :steer)
    entry = Enum.find(ModelConfig.available_models_for_workspace(path), &(&1.id == model))

    with true <- is_binary(model),
         {:ok, config, model_id} <- ModelConfig.resolve_model_for_workspace(path, model),
         :ok <-
           Handbeam.Agent.ModelCapabilities.validate_inputs(
             entry,
             HandbeamProbe.NativeModelInputs.required_inputs(attachments)
           ),
         {:ok, review_opts} <- review_run_opts(conversation["id"], opts),
         {:ok, message, persistable} <-
           Handbeam.Attachments.MessageBuilder.build(content, attachments,
             workspace_path: path,
             conversation_id: conversation["id"],
             staging_roots: Application.get_env(:handbeam_probe, :staging_roots, [])
           ) do
      config = Reasoning.apply_provider_options(config, entry, settings.reasoning)
      runtime_opts = Handbeam.Settings.ModelAISettings.to_runtime_opts(settings)
      message = put_inbound_message_id(message, inbound_id)

      case Coordinator.add_message(
             conversation["id"],
             message,
             Keyword.merge(
               runtime_opts,
               Keyword.merge(
                 [
                   provider_config: config,
                   model: model_id,
                   tools: Handbeam.Agent.default_tools(),
                   workspace_id: workspace["id"],
                   workspace_path: path,
                   source: :native,
                   streaming: true,
                   deliver_as: deliver_as,
                   inbound_id: inbound_id,
                   transcript_id: inbound_id,
                   message_id: inbound_id,
                   attachments: persistable
                 ],
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

  defp safe_snapshot(id) do
    Session.snapshot(id)
  catch
    :exit, _ -> %{events: []}
  end

  defp running?(id) do
    match?({:ok, %{running?: true}}, Coordinator.status(id))
  end

  defp still_running?(%{kind: :run_end, payload: payload}, state, _id) do
    status = event_payload(payload)["status"]
    state.pending_approval != nil or status in [:interrupted, "interrupted"]
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
    |> read_transcript(opts)
    |> NativeLocalImage.resolve_entries(Map.get(state, :workspace_path), id)
  end

  defp read_transcript(id, opts) do
    case Keyword.get(opts, :transcript) do
      fun when is_function(fun, 1) -> fun.(id)
      _ -> transcript(id)
    end
  end

  defp approval(%{kind: :tool_approval_requested, payload: payload, seq: seq}, state),
    do: %{state | pending_approval: event_payload(payload), approval_seq: seq}

  defp approval(%{kind: :run_end, payload: payload}, state) do
    if event_payload(payload)["status"] in [:interrupted, "interrupted"],
      do: state,
      else: %{state | pending_approval: nil, approval_seq: nil}
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

  defp delta(%{kind: :message_delta, payload: %{chunk: chunk}}, state) do
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

  defp delta(%{kind: :thinking_delta}, state), do: %{state | thinking: true}

  defp delta(_event, state), do: state
end

defmodule Handbeam.PubSub.Session do
  @moduledoc """
  Session GenServer — manages agent session lifecycle and event snapshot.

  One Session per conversation. Maintains:
  - Event sequence counter
  - Event snapshot for reconnection replay
  - Agent state reference

  ## Design

  All events for a session go through a single PubSub topic.
  The Session maintains a snapshot of the last N events for reconnection.
  """

  use GenServer

  alias Handbeam.Agent.Message
  alias Handbeam.PubSub.AgentEvent

  require Logger

  @max_snapshot_events 500
  @throttle_default_ms 50

  # Disk-save throttle window for high-frequency events (e.g. :message_delta).
  # Structural events (run_start, tool_start/end, run_end) always force-save.
  @save_throttle_ms 500

  # Events that are emitted at high frequency during streaming.
  # These are broadcast via cast (no waiting) and their disk snapshot is throttled.
  @high_freq_events [:message_delta, :thinking_delta]

  @doc false
  def throttle_default_ms, do: @throttle_default_ms

  @doc "Start a new session or return existing one."
  def start_or_get(opts \\ []) do
    case Handbeam.SessionSupervisor.start_session(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc "Start a new session."
  def start_link(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, Ecto.UUID.generate())
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  @doc "Get session PID by id."
  def whereis(session_id) do
    case Registry.lookup(Handbeam.SessionRegistry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Broadcast a pre-built AgentEvent to the session topic and append to snapshot."
  @spec broadcast(String.t(), AgentEvent.t()) :: :ok
  def broadcast(session_id, %AgentEvent{} = event) do
    topic = session_topic(session_id)
    Phoenix.PubSub.broadcast(Handbeam.PubSub, topic, {:agent_event, event})

    pid = whereis(session_id)
    if pid, do: GenServer.cast(pid, {:append, event})

    :ok
  end

  @doc """
  Broadcast an event with auto-incrementing seq.

  The Session GenServer manages the seq counter internally,
  ensuring monotonic ordering. Creates an AgentEvent struct
  and broadcasts via Phoenix.PubSub + appends to snapshot.

  All events use `GenServer.cast` so the agent task is never blocked by
  disk IO. High-frequency events (`#{inspect(@high_freq_events)}`) have
  their on-disk snapshot throttled (see `@save_throttle_ms`). All other
  events force-save to guarantee durability at run boundaries.
  """
  @spec broadcast_event(String.t(), AgentEvent.kind(), map()) :: :ok
  def broadcast_event(session_id, kind, payload) do
    log_broadcast_request(session_id, kind, payload)

    case whereis(session_id) do
      nil ->
        Logger.debug(
          "[Session] broadcast skipped; no session pid session=#{session_id} kind=#{kind}"
        )

        :ok

      pid ->
        GenServer.cast(pid, {:broadcast_event, kind, payload})
    end

    :ok
  end

  @doc "Subscribe to a session topic."
  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(Handbeam.PubSub, session_topic(session_id))
  end

  @doc "Unsubscribe from a session topic."
  def unsubscribe(session_id) do
    Phoenix.PubSub.unsubscribe(Handbeam.PubSub, session_topic(session_id))
  end

  @doc "PubSub topic for a session."
  def session_topic(session_id), do: "session:#{session_id}"

  @doc "Get the current snapshot for reconnection."
  def snapshot(session_id) do
    GenServer.call(via_tuple(session_id), :snapshot)
  end

  @doc "Append an event to the snapshot."
  def append_event(session_id, %AgentEvent{} = event) do
    GenServer.cast(via_tuple(session_id), {:append, event})
  end

  @doc "Update session metadata."
  def update_meta(session_id, key, value) do
    GenServer.cast(via_tuple(session_id), {:update_meta, key, value})
  end

  @doc "Update a key in extension state."
  def update_extension_state(session_id, extension_name, key, value) do
    GenServer.cast(via_tuple(session_id), {:update_extension_state, extension_name, key, value})
  end

  @doc "Delete a key from extension state."
  def delete_extension_state(session_id, extension_name, key) do
    GenServer.cast(via_tuple(session_id), {:delete_extension_state, extension_name, key})
  end

  @doc "Attach an active agent run and its candidate queue to this session."
  def attach_run(session_id, agent_pid, queue_pid, opts \\ []) do
    GenServer.call(via_tuple(session_id), {:attach_run, agent_pid, queue_pid, opts})
  end

  @doc "Enqueue a candidate message for the active run or next turn."
  def enqueue_candidate(session_id, content, opts \\ []) do
    GenServer.call(via_tuple(session_id), {:enqueue_candidate, content, opts})
  end

  @doc "Get all pending messages in candidate queue or next turn."
  @spec get_pending_messages(String.t()) :: [map()]
  def get_pending_messages(session_id) do
    case whereis(session_id) do
      nil -> []
      pid -> GenServer.call(pid, :get_pending_messages)
    end
  end

  @doc "Delete a pending message from candidate queue or next turn."
  @spec delete_pending_message(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_pending_message(session_id, message_id) do
    case whereis(session_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:delete_pending_message, message_id})
    end
  end

  @doc "Drain messages that should be prepended to the next user turn."
  def drain_next_turn(session_id) do
    GenServer.call(via_tuple(session_id), :drain_next_turn)
  end

  @doc "Mark the active run finished and seal its queue."
  def mark_run_finished(session_id) do
    GenServer.call(via_tuple(session_id), :mark_run_finished)
  end

  # ── Server Callbacks ──

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    model = Keyword.get(opts, :model, "unknown")

    loaded = load_snapshot(session_id, opts)

    state = %{
      session_id: session_id,
      model: model,
      seq: Map.get(loaded, "seq", 0),
      events: load_events(Map.get(loaded, "events", [])),
      meta: %{
        created_at: DateTime.utc_now(),
        status: :active,
        running?: false,
        agent_pid: nil,
        queue_pid: nil,
        run_id: nil,
        model: Map.get(loaded, "model", model),
        workspace_path: Keyword.get(opts, :workspace_path)
      },
      agent_pid: nil,
      queue_pid: nil,
      next_turn_messages: load_messages(Map.get(loaded, "next_turn_messages", [])),
      extension_state: Map.get(loaded, "extension_state", %{}),
      last_throttle: 0,
      store_opts: store_opts(opts),
      recorder_opts: recorder_opts(opts)
    }

    Logger.debug("[Session] Created #{session_id} (model: #{model})")
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       last_seq: state.seq,
       events: state.events,
       meta: state.meta,
       extension_state: state.extension_state
     }, state}
  end

  def handle_call({:attach_run, agent_pid, queue_pid, opts}, _from, state) do
    Process.monitor(agent_pid)
    Process.monitor(queue_pid)
    run_id = Keyword.get(opts, :run_id)

    meta = %{
      state.meta
      | running?: true,
        agent_pid: agent_pid,
        queue_pid: queue_pid,
        run_id: run_id,
        workspace_path: Keyword.get(opts, :workspace_path, state.meta.workspace_path)
    }

    new_state = %{state | agent_pid: agent_pid, queue_pid: queue_pid, meta: meta}
    new_state = maybe_save(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:enqueue_candidate, content, opts}, _from, state) do
    deliver_as = Keyword.get(opts, :deliver_as, :steer)

    case deliver_as do
      :next_turn ->
        message = normalize_message(content, opts)
        new_state = %{state | next_turn_messages: state.next_turn_messages ++ [message]}
        new_state = maybe_save(new_state)

        broadcast_event(state.session_id, :candidate_message_injected, %{
          message_id: message.id,
          content: message.content,
          deliver_as: :next_turn
        })

        {:reply, :ok, new_state}

      kind when kind in [:steer, :follow_up] ->
        case state.queue_pid do
          nil ->
            {:reply, {:error, :no_active_run}, state}

          queue_pid ->
            {content, opts} = stamp_queue_ids(content, opts)

            case Handbeam.Agent.CandidateQueue.enqueue(queue_pid, content, opts) do
              :ok ->
                broadcast_event(state.session_id, :candidate_message_injected, %{
                  message_id: Keyword.fetch!(opts, :message_id),
                  content: message_text(content),
                  deliver_as: kind
                })

                {:reply, :ok, state}

              other ->
                {:reply, other, state}
            end
        end

      _ ->
        {:reply, {:error, :invalid_deliver_as}, state}
    end
  end

  def handle_call(:get_pending_messages, _from, state) do
    queue_msgs =
      case state.queue_pid do
        nil ->
          []

        queue_pid ->
          try do
            Handbeam.Agent.CandidateQueue.get_messages(queue_pid)
            |> Enum.map(fn %{message: msg, metadata: meta} ->
              %{
                id: msg.id,
                content: msg.content,
                role: msg.role,
                deliver_as: meta.deliver_as
              }
            end)
          catch
            :exit, _ -> []
          end
      end

    next_turn_msgs =
      state.next_turn_messages
      |> Enum.map(fn msg ->
        %{
          id: msg.id,
          content: msg.content,
          role: msg.role,
          deliver_as: :next_turn
        }
      end)

    {:reply, queue_msgs ++ next_turn_msgs, state}
  end

  def handle_call({:delete_pending_message, message_id}, _from, state) do
    case Enum.split_with(state.next_turn_messages, &(&1.id == message_id)) do
      {[_deleted], remaining} ->
        new_state = %{state | next_turn_messages: remaining}
        new_state = maybe_save(new_state)
        broadcast_event(state.session_id, :candidate_message_deleted, %{message_id: message_id})
        {:reply, {:ok, %{deliver_as: :next_turn}}, new_state}

      {[], _} ->
        case state.queue_pid do
          nil ->
            {:reply, {:error, :not_found}, state}

          queue_pid ->
            case Handbeam.Agent.CandidateQueue.delete_message(queue_pid, message_id) do
              {:ok, _count} ->
                broadcast_event(state.session_id, :candidate_message_deleted, %{
                  message_id: message_id
                })

                {:reply, {:ok, %{deliver_as: :steer}}, state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end
        end
    end
  end

  def handle_call(:drain_next_turn, _from, state) do
    new_state = %{state | next_turn_messages: []}
    new_state = maybe_save(new_state)
    {:reply, state.next_turn_messages, new_state}
  end

  def handle_call(:mark_run_finished, _from, state) do
    safe_seal_queue(state.queue_pid)

    meta = %{state.meta | running?: false, agent_pid: nil, queue_pid: nil, run_id: nil}
    new_state = %{state | agent_pid: nil, queue_pid: nil, meta: meta}
    new_state = maybe_save(new_state)
    Logger.debug("[Session] run finished session=#{state.session_id}")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:broadcast_event, kind, payload}, state) do
    # Cast path: used for high-frequency events; throttle disk saves to avoid
    # blocking the agent task on slow filesystems.
    force? = kind not in @high_freq_events
    new_state = do_broadcast_event(state, kind, payload, force_save?: force?)
    {:noreply, new_state}
  end

  def handle_cast({:append, %AgentEvent{} = event}, state) do
    new_events = Enum.take([event | state.events], @max_snapshot_events)

    new_state = %{state | seq: max(state.seq, event.seq), events: new_events}
    maybe_record_event(new_state, event)
    new_state = maybe_save_throttled(new_state, force?: event.kind not in @high_freq_events)
    {:noreply, new_state}
  end

  def handle_cast({:update_meta, key, value}, state) do
    new_state = put_in(state.meta[key], value)
    new_state = maybe_save(new_state)
    {:noreply, new_state}
  end

  def handle_cast({:update_extension_state, extension_name, key, value}, state) do
    new_state =
      put_in(
        state,
        [:extension_state, Access.key(extension_name, %{}), key],
        value
      )

    new_state = maybe_save(new_state)
    {:noreply, new_state}
  end

  def handle_cast({:delete_extension_state, extension_name, key}, state) do
    ext_state =
      case Map.get(state.extension_state, extension_name) do
        nil -> state.extension_state
        inner -> %{state.extension_state | extension_name => Map.delete(inner, key)}
      end

    # Clean up empty extension maps
    ext_state =
      case Map.get(ext_state, extension_name) do
        m when m == %{} -> Map.delete(ext_state, extension_name)
        _ -> ext_state
      end

    new_state = %{state | extension_state: ext_state}
    new_state = maybe_save(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      pid == state.agent_pid ->
        Process.demonitor(ref, [:flush])

        Logger.warning(fn ->
          "[Session] agent process down session=#{state.session_id} reason=#{inspect(reason)}"
        end)

        safe_seal_queue(state.queue_pid)
        meta = %{state.meta | running?: false, agent_pid: nil, queue_pid: nil, run_id: nil}
        new_state = %{state | agent_pid: nil, queue_pid: nil, meta: meta}
        new_state = maybe_save(new_state)
        {:noreply, new_state}

      pid == state.queue_pid ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{state | queue_pid: nil}}

      true ->
        {:noreply, state}
    end
  end

  # ── Helpers ──

  defp stamp_queue_ids(content, opts) do
    struct_id =
      case content do
        %Message{id: id} when is_binary(id) and id != "" -> id
        _ -> nil
      end

    opt_message_id = present_queue_id(Keyword.get(opts, :message_id))
    opt_transcript_id = present_queue_id(Keyword.get(opts, :transcript_id))
    canonical = opt_message_id || opt_transcript_id || struct_id || Ecto.UUID.generate()

    content =
      case content do
        %Message{} = message -> %{message | id: canonical}
        other -> other
      end

    {content, Keyword.put(opts, :message_id, canonical)}
  end

  defp present_queue_id(id) when is_binary(id) and id != "", do: id
  defp present_queue_id(_), do: nil

  defp normalize_message(%Message{} = message, opts) do
    %{message | id: message.id || Keyword.get(opts, :message_id)}
  end

  defp normalize_message(content, opts) when is_binary(content) do
    %Message{role: :user, content: content, id: Keyword.get(opts, :message_id)}
  end

  defp message_text(%Message{} = message), do: Message.text(message) || ""
  defp message_text(content) when is_binary(content), do: content
  defp message_text(content), do: inspect(content)

  defp load_snapshot(session_id, opts) do
    if session_store_enabled?(opts) do
      case Handbeam.SessionStore.File.load(session_id, opts) do
        {:ok, snapshot} -> snapshot
        {:error, _reason} -> %{}
      end
    else
      %{}
    end
  end

  defp load_events(events) when is_list(events) do
    events
    |> Enum.map(fn
      %AgentEvent{} = event -> event
      %{} = event -> struct(AgentEvent, atomize_known_keys(event))
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp load_events(_events), do: []

  defp load_messages(messages) when is_list(messages) do
    messages
    |> Enum.map(fn
      %Message{} = message -> message
      %{} = message -> struct(Message, atomize_known_keys(message))
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp load_messages(_messages), do: []

  defp atomize_known_keys(map) do
    Map.new(map, fn
      {"seq", value} -> {:seq, value}
      {"topic", value} -> {:topic, value}
      {"kind", value} -> {:kind, maybe_existing_atom(value)}
      {"payload", value} -> {:payload, value}
      {"ts_ms", value} -> {:ts_ms, value}
      {"role", value} -> {:role, maybe_existing_atom(value)}
      {"content", value} -> {:content, value}
      {key, value} when is_atom(key) -> {key, value}
      {key, value} -> {key, value}
    end)
  end

  defp maybe_existing_atom(value) when is_binary(value) do
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> value
    end
  end

  defp maybe_existing_atom(value), do: value

  # Core broadcast/append/persist pipeline shared by call and cast paths.
  defp do_broadcast_event(state, kind, payload, opts) do
    seq = state.seq + 1
    topic = session_topic(state.session_id)
    event = AgentEvent.new(topic, kind, payload, seq)

    log_broadcast_event(state.session_id, event)
    Phoenix.PubSub.broadcast(Handbeam.PubSub, topic, {:agent_event, event})
    maybe_broadcast_run_lifecycle(state.session_id, event)

    new_events = Enum.take([event | state.events], @max_snapshot_events)
    new_state = %{state | seq: seq, events: new_events}

    maybe_record_event(new_state, event)
    maybe_save_throttled(new_state, force?: Keyword.get(opts, :force_save?, true))
  end

  defp log_broadcast_request(_session_id, :message_delta, %{chunk: chunk})
       when is_binary(chunk) do
    :ok
  end

  defp log_broadcast_request(_session_id, kind, _payload) when kind in @high_freq_events do
    :ok
  end

  defp log_broadcast_request(session_id, kind, _payload) do
    if kind not in [:message_delta, :user_on_chunk] do
      Logger.debug("[Session] broadcast_event request #{kind} session=#{session_id}")
    end
  end

  defp log_broadcast_event(_session_id, %{
         kind: :message_delta,
         seq: _seq,
         payload: %{chunk: chunk}
       })
       when is_binary(chunk) do
    :ok
  end

  defp log_broadcast_event(_session_id, %{kind: kind}) when kind in @high_freq_events do
    :ok
  end

  defp log_broadcast_event(session_id, %{kind: kind, seq: seq}) do
    Logger.debug("[Session] broadcasting #{kind} session=#{session_id} seq=#{seq}")
  end

  defp maybe_record_event(state, event) do
    if event_recorder_enabled?(state.recorder_opts) do
      Handbeam.EventRecorder.record(state.session_id, event, state.recorder_opts)
    end
  end

  defp maybe_save(state) do
    if session_store_enabled?(state.store_opts) do
      Handbeam.SessionStore.File.save(state.session_id, session_snapshot(state), state.store_opts)
    end

    %{state | last_throttle: System.monotonic_time(:millisecond)}
  end

  # Skip disk save for high-frequency events unless the throttle window has
  # elapsed. This is the main mitigation against per-chunk fsync stalls on
  # slow filesystems (notably WSL2 -> Windows /mnt/*).
  defp maybe_save_throttled(state, opts) do
    force? = Keyword.get(opts, :force?, true)
    now = System.monotonic_time(:millisecond)
    elapsed = now - (state.last_throttle || 0)

    cond do
      force? ->
        maybe_save(state)

      elapsed >= @save_throttle_ms ->
        maybe_save(state)

      true ->
        state
    end
  end

  defp session_snapshot(state) do
    %{
      "seq" => state.seq,
      "events" => Enum.map(state.events, &Map.from_struct/1),
      "running?" => state.meta.running?,
      "model" => state.model,
      "next_turn_messages" => Enum.map(state.next_turn_messages, &Map.from_struct/1),
      "extension_state" => state.extension_state
    }
  end

  defp event_recorder_enabled?(opts) do
    Keyword.get(
      opts,
      :event_recorder_enabled?,
      Application.get_env(:handbeam, :event_recorder_enabled?, true)
    )
  end

  defp session_store_enabled?(opts) do
    Keyword.get(
      opts,
      :session_store_enabled?,
      Application.get_env(:handbeam, :session_store_enabled?, true)
    )
  end

  defp store_opts(opts) do
    opts
    |> Keyword.take([:session_store_dir, :session_store_enabled?])
  end

  defp recorder_opts(opts) do
    opts
    |> Keyword.take([:event_dir, :event_recorder_enabled?])
  end

  defp safe_seal_queue(queue_pid) when is_pid(queue_pid) do
    Handbeam.Agent.CandidateQueue.seal(queue_pid)
  catch
    :exit, _reason -> :ok
  end

  defp safe_seal_queue(_queue_pid), do: :ok

  defp maybe_broadcast_run_lifecycle(session_id, %{kind: kind, payload: payload})
       when kind in [:run_start, :run_end, :tool_approval_requested] do
    Phoenix.PubSub.broadcast(
      Handbeam.PubSub,
      "runtime:runs",
      {:run_lifecycle, session_id, kind, payload}
    )
  end

  defp maybe_broadcast_run_lifecycle(_session_id, _event), do: :ok

  defp via_tuple(session_id), do: {:via, Registry, {Handbeam.SessionRegistry, session_id}}
end

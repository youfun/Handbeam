defmodule Handbeam.Agent.Runner do
  @moduledoc """
  GenServer owner for one active agent run.

  Runner owns lifecycle state and delegates the expensive agent loop to
  `Handbeam.AgentRunTaskSupervisor` via `Task.Supervisor.async_nolink/2`.
  """

  use GenServer

  require Logger

  alias Handbeam.PubSub.Session

  @default_inactivity_timeout_ms 300_000
  @progress_events [
    :message_delta,
    :thinking_delta,
    :provider_items,
    :provider_retry,
    :tool_start,
    :tool_end,
    :turn_start,
    :turn_end,
    :candidate_message_injected,
    :tool_approval_requested,
    :stall_check_requested
  ]

  defstruct [
    :conversation_id,
    :content,
    :opts,
    :queue_pid,
    :task,
    :status,
    :error,
    :result,
    :interrupted_state,
    :delegation_monitor,
    :started_at,
    :deadline,
    :deadline_timer,
    os_processes: []
  ]

  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Handbeam.AgentRunRegistry, conversation_id}}
    )
  end

  def start_run(conversation_id, content, opts) do
    Handbeam.AgentRunSupervisor.start_run(conversation_id, content, opts)
  end

  def status(conversation_id) do
    call_runner(conversation_id, :status)
  end

  @doc "Nonblocking identity check for owners monitoring a run scope."
  def active?(conversation_id, run_id, pid) do
    case Registry.lookup(Handbeam.AgentRunRegistry, conversation_id) do
      [{^pid, %{run_id: ^run_id, active?: true}}] -> Process.alive?(pid)
      _ -> false
    end
  end

  def cancel(conversation_id) do
    call_runner(conversation_id, :cancel)
  end

  def resume(conversation_id, decisions) do
    call_runner(conversation_id, {:resume, decisions})
  end

  def enqueue(conversation_id, content, opts \\ []) do
    call_runner(conversation_id, {:enqueue, content, opts})
  end

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    queue_pid = resolve_queue_pid!(Keyword.fetch!(opts, :queue_name))
    content = Keyword.fetch!(opts, :content)
    run_opts = Keyword.fetch!(opts, :run_opts)

    # Delegated tasks stay linked so killing their Runner also kills the task.
    # Trap task exits so the monitor's DOWN can durably close a crashed child run.
    if run_opts[:delegated?], do: Process.flag(:trap_exit, true)

    state = %__MODULE__{
      conversation_id: conversation_id,
      content: content,
      opts: Keyword.put(run_opts, :runner_pid, self()),
      queue_pid: queue_pid,
      status: :idle
    }

    with :ok <- attach_delegation(run_opts, conversation_id),
         :ok <- accept_inbound(conversation_id, content, run_opts) do
      owner = Keyword.get(run_opts, :delegation_owner)
      monitor = if is_pid(owner), do: Process.monitor(owner)
      {:ok, %{state | delegation_monitor: monitor}, {:continue, :start_task}}
    else
      {:error, reason} ->
        {:stop, {:inbound_persist_failed, reason}}
    end
  end

  defp attach_delegation(opts, conversation_id) do
    case Keyword.get(opts, :delegation_owner) do
      nil -> :ok
      owner -> Handbeam.Agent.Delegation.attach(owner, conversation_id, self())
    end
  end

  # Accepted new-run inbound is written here so
  # exclusive RunSupervisor start is the accept gate and the user entry exists
  # before handle_continue starts the provider task.
  defp accept_inbound(conversation_id, content, opts) do
    if Keyword.get(opts, :persist_inbound?, true) do
      inbound_opts = Keyword.put(opts, :deliver_as, :new_run)

      case Handbeam.Agent.TranscriptPersistence.append_inbound(
             conversation_id,
             content,
             inbound_opts
           ) do
        {:ok, _} -> :ok
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  @impl true
  def handle_continue(:start_task, state) do
    prewarm_search(state)

    Registry.update_value(Handbeam.AgentRunRegistry, state.conversation_id, fn _ ->
      %{run_id: state.opts[:run_id], active?: true}
    end)

    if job_context_present?(state) do
      case Handbeam.Jobs.open_run(job_context(state), self()) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("[Runner] job scope unavailable: #{reason}")
      end
    end

    :ok =
      Session.attach_run(state.conversation_id, self(), state.queue_pid,
        run_id: Keyword.get(state.opts, :run_id),
        run_supervisor: state.opts[:run_supervisor],
        workspace_path: Keyword.get(state.opts, :workspace_path),
        model: Keyword.get(state.opts, :model)
      )

    started_at = System.monotonic_time(:millisecond)
    {deadline, timer} = arm_timeout(state)

    run_opts =
      state.opts
      |> Keyword.put(:candidate_queue, state.queue_pid)
      |> maybe_put_run_deadline(state, deadline)
      |> put_persistence_callback(state.conversation_id)

    start_task = if state.opts[:delegated?], do: :async, else: :async_nolink

    task =
      apply(Task.Supervisor, start_task, [
        Handbeam.AgentRunTaskSupervisor,
        fn ->
          owner = run_opts[:delegation_owner]

          with :ok <-
                 if(owner,
                   do: Handbeam.Agent.Delegation.attach_task(owner, state.conversation_id),
                   else: :ok
                 ) do
            Handbeam.Agent.run(state.content, run_opts)
          end
        end
      ])

    {:noreply,
     %{
       state
       | status: :running,
         task: task,
         started_at: started_at,
         deadline: deadline,
         deadline_timer: timer
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     {:ok,
      %{
        conversation_id: state.conversation_id,
        running?: state.status in [:running, :awaiting_approval],
        status: state.status,
        run_pid: self(),
        run_id: state.opts[:run_id],
        run_supervisor: state.opts[:run_supervisor],
        queue_pid: state.queue_pid,
        deadline: state.deadline,
        error: state.error,
        interrupt_type: interrupt_type(state)
      }}, state}
  end

  def handle_call(:cancel, from, %{status: status, task: task} = state)
      when status in [:running, :awaiting_approval] do
    cleanup_os_processes(state)
    close_scope(state)
    shutdown_run_task(task)
    persist_cancelled_run(state)
    Handbeam.Agent.CandidateQueue.seal(state.queue_pid)

    Session.broadcast_event(state.conversation_id, :run_end, %{
      status: "cancelled",
      turns: 0,
      run_id: state.opts[:run_id]
    })

    Session.mark_run_finished(state.conversation_id, state.opts[:run_id])
    # Teardown may terminate this Runner immediately; acknowledge before launching it.
    GenServer.reply(from, :ok)
    stop_run_supervisor(state)
    {:noreply, %{state | status: :cancelled, task: nil, interrupted_state: nil}}
  end

  def handle_call(:cancel, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call({:resume, decisions}, _from, %{status: :awaiting_approval} = state) do
    {deadline, timer} = resume_timeout(state)

    run_opts =
      state.opts
      |> Keyword.put(:candidate_queue, state.queue_pid)
      |> maybe_put_run_deadline(state, deadline)
      |> put_persistence_callback(state.conversation_id)

    resume = resume_fun(state)

    Session.broadcast_event(state.conversation_id, :run_resumed, %{run_id: state.opts[:run_id]})

    task =
      Task.Supervisor.async_nolink(Handbeam.AgentRunTaskSupervisor, fn ->
        resume.(state.interrupted_state, decisions, run_opts)
      end)

    {:reply, :ok,
     %{
       state
       | status: :running,
         task: task,
         interrupted_state: nil,
         deadline: deadline,
         deadline_timer: timer
     }}
  end

  def handle_call({:resume, _decisions}, _from, state) do
    {:reply, {:error, :not_awaiting_approval}, state}
  end

  def handle_call({:enqueue, content, opts}, _from, state) do
    reply = Handbeam.Agent.CandidateQueue.enqueue(state.queue_pid, content, opts)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{delegation_monitor: ref} = state)
      when is_reference(ref) do
    shutdown_run_task(state.task)
    persist_cancelled_run(state)
    Session.mark_run_finished(state.conversation_id, state.opts[:run_id])
    stop_run_supervisor(state)
    {:stop, :normal, %{state | task: nil}}
  end

  def handle_info({ref, {:ok, _result}}, %{task: %{ref: ref}, status: :timeout} = state) do
    Process.demonitor(ref, [:flush])
    Logger.debug("[Runner] dropped late result after run deadline ref=#{inspect(ref)}")
    {:noreply, %{state | task: nil}}
  end

  def handle_info({ref, {:ok, result}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      %Handbeam.Agent.State{status: :interrupted} = interrupted ->
        if absolute_timeout?(state) do
          {:noreply,
           %{state | status: :awaiting_approval, interrupted_state: interrupted, task: nil}}
        else
          cancel_timeout(state.deadline_timer)

          {:noreply,
           %{
             state
             | status: :awaiting_approval,
               interrupted_state: interrupted,
               task: nil,
               deadline: nil,
               deadline_timer: nil
           }}
        end

      %Handbeam.Agent.State{status: :halted} = halted ->
        finish_terminal(state, halted, :halted)

      %Handbeam.Agent.State{status: status} = result ->
        finish_terminal(state, result, status)

      _ ->
        finish_terminal(state, result, :completed)
    end
  end

  def handle_info({ref, {:error, reason}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Handbeam.Agent.Provider.Cursor.Session.stop_for_conversation(state.conversation_id)
    finish_error(state, reason)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    Handbeam.Agent.Provider.Cursor.Session.stop_for_conversation(state.conversation_id)
    finish_error(state, reason)
  end

  def handle_info({:os_process_started, os_pid, invocation}, state)
      when is_integer(os_pid) do
    {:noreply, %{state | os_processes: [{os_pid, invocation} | state.os_processes]}}
  end

  def handle_info({:run_progress, run_id, kind}, state)
      when state.status == :running and kind in @progress_events do
    if state.opts[:run_id] == run_id and not absolute_timeout?(state) do
      cancel_timeout(state.deadline_timer)
      {deadline, timer} = arm_timeout(state)
      {:noreply, %{state | deadline: deadline, deadline_timer: timer}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:run_deadline, deadline}, %{deadline: deadline} = state)
      when state.status in [:running, :awaiting_approval] do
    cleanup_os_processes(state)
    shutdown_run_task(state.task)

    payload = %{
      status: "timeout",
      turns: 0,
      error: "run deadline exceeded",
      reason: :run_timeout,
      execution: :unknown,
      run_id: state.opts[:run_id]
    }

    persist_terminal_event(state, payload)
    Session.broadcast_event(state.conversation_id, :run_end, payload)
    Session.mark_run_finished(state.conversation_id, state.opts[:run_id])
    Handbeam.Agent.CandidateQueue.seal(state.queue_pid)
    stop_run_supervisor(state)

    {:stop, :shutdown, %{state | status: :timeout, task: nil, deadline_timer: nil}}
  end

  def handle_info({:run_deadline, _stale}, state), do: {:noreply, state}

  def handle_info({:run_inactivity, deadline}, %{deadline: deadline, status: :running} = state) do
    timeout_ms = timeout_ms(state)
    cleanup_os_processes(state)
    shutdown_run_task(state.task)

    payload = %{
      status: "timeout",
      turns: 0,
      error: "run stalled: no progress for #{timeout_ms}ms",
      reason: :run_inactivity_timeout,
      execution: :unknown,
      run_id: state.opts[:run_id]
    }

    persist_terminal_event(state, payload)
    Session.broadcast_event(state.conversation_id, :run_end, payload)
    Session.mark_run_finished(state.conversation_id, state.opts[:run_id])
    Handbeam.Agent.CandidateQueue.seal(state.queue_pid)
    stop_run_supervisor(state)

    {:stop, :shutdown, %{state | status: :timeout, task: nil, deadline_timer: nil}}
  end

  def handle_info({:run_inactivity, _stale}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, reason}, state) when reason not in [:normal, :shutdown] do
    abort_unreplayable(state, {:run_tree_exit, reason})
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def abort_unreplayable(state, reason) do
    shutdown_run_task(state.task)
    Handbeam.Agent.CandidateQueue.seal(state.queue_pid)

    payload = %{
      status: "error",
      turns: 0,
      error: inspect(reason),
      execution: :unknown,
      replayed: false,
      run_id: state.opts[:run_id]
    }

    persist_terminal_event(state, payload)
    Session.broadcast_event(state.conversation_id, :run_end, payload)
    Session.mark_run_finished(state.conversation_id, state.opts[:run_id])
    Logger.error("[Runner] run aborted without replay: #{inspect(reason)}")
    stop_run_supervisor(state)
    {:stop, :normal, %{state | status: :error, error: reason, task: nil}}
  end

  defp finish_terminal(state, result, status) do
    Handbeam.Agent.Provider.Cursor.Session.stop_for_conversation(state.conversation_id)
    Handbeam.Agent.CandidateQueue.seal(state.queue_pid)
    Session.mark_run_finished(state.conversation_id, state.opts[:run_id])

    Task.Supervisor.start_child(Handbeam.AgentRunTaskSupervisor, fn ->
      Handbeam.Threads.Collaboration.completed(state.conversation_id, result, state.opts)
    end)

    stop_run_supervisor(state)
    {:noreply, %{state | status: status, result: result, task: nil}}
  end

  defp interrupt_type(%{status: :awaiting_approval, interrupted_state: %{interrupt_data: data}})
       when is_map(data) do
    data[:type] || data["type"]
  end

  defp interrupt_type(_state), do: nil

  defp resume_fun(state) do
    if interrupt_type(state) == :stall_check do
      &Handbeam.Agent.resume_after_stall_check/3
    else
      &Handbeam.Agent.resume_after_tool_approval/3
    end
  end

  defp cleanup_os_processes(state) do
    Enum.each(state.os_processes, fn {os_pid, invocation} ->
      Handbeam.Platform.ProcessRunner.cleanup_owned(os_pid, invocation)
    end)
  end

  defp shutdown_run_task(nil), do: :ok

  defp shutdown_run_task(%Task{} = task) do
    if is_pid(task.pid), do: send(task.pid, :run_cancelled)
    _ = Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp arm_timeout(state) do
    timeout = timeout_ms(state)
    deadline = System.monotonic_time(:millisecond) + timeout

    message =
      if absolute_timeout?(state),
        do: {:run_deadline, deadline},
        else: {:run_inactivity, deadline}

    {deadline, Process.send_after(self(), message, timeout)}
  end

  defp resume_timeout(state) do
    if absolute_timeout?(state),
      do: {state.deadline, state.deadline_timer},
      else: arm_timeout(state)
  end

  defp timeout_ms(state),
    do: Keyword.get(state.opts, :timeout_ms, @default_inactivity_timeout_ms)

  defp absolute_timeout?(state), do: Keyword.get(state.opts, :delegated?, false)

  defp maybe_put_run_deadline(opts, state, deadline) do
    if absolute_timeout?(state),
      do: Keyword.put(opts, :run_deadline, deadline),
      else: Keyword.delete(opts, :run_deadline)
  end

  defp cancel_timeout(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timeout(_), do: false

  defp persist_cancelled_run(state) do
    payload = %{status: "cancelled", turns: 0, run_id: state.opts[:run_id]}

    payload =
      case state.interrupted_state do
        %{usage: usage, turn: turn} when is_map(usage) ->
          payload |> Map.put(:usage, usage) |> Map.put(:turns, turn)

        _ ->
          payload
      end

    persist_terminal_event(state, payload)
  end

  defp persist_terminal_event(state, payload) do
    case Handbeam.Agent.TranscriptPersistence.handle_event(
           state.conversation_id,
           {:run_end, payload},
           state.opts
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Runner] terminal transcript persist failed conversation=#{state.conversation_id} " <>
            "reason=#{inspect(reason)}"
        )
    end
  rescue
    error ->
      # An unavailable disk must not crash/restart Runner and execute the run
      # again. Persisted streaming entries remain recoverable on the next boot.
      Logger.error("[Runner] terminal transcript persist failed: #{Exception.message(error)}")
  catch
    :exit, reason ->
      Logger.error("[Runner] terminal transcript owner unavailable: #{inspect(reason)}")
  end

  defp finish_error(state, reason) do
    message = inspect(reason)
    Handbeam.Agent.CandidateQueue.seal(state.queue_pid)

    payload = %{
      status: "error",
      turns: 0,
      error: message,
      run_id: state.opts[:run_id]
    }

    persist_terminal_event(state, payload)
    Session.broadcast_event(state.conversation_id, :run_end, payload)

    Session.mark_run_finished(state.conversation_id, state.opts[:run_id])
    Logger.error("[Runner] Agent run failed: #{message}")
    stop_run_supervisor(state)
    {:noreply, %{state | status: :error, error: reason, task: nil}}
  end

  defp stop_run_supervisor(state) do
    close_scope(state)

    case state.opts[:run_supervisor] do
      pid when is_pid(pid) ->
        Task.Supervisor.start_child(Handbeam.AgentRunTaskSupervisor, fn ->
          Handbeam.AgentRunSupervisor.stop_run(pid)
        end)

      _ ->
        :ok
    end

    :ok
  end

  defp close_scope(state) do
    Handbeam.Tool.Builtin.Computer.stop(state.conversation_id, state.opts[:run_id])

    Registry.update_value(Handbeam.AgentRunRegistry, state.conversation_id, fn metadata ->
      Map.put(metadata || %{}, :active?, false)
    end)

    if job_context_present?(state), do: Handbeam.Jobs.close_run(job_context(state), :completed)
    Handbeam.Agent.Provider.Cursor.Session.stop_for_conversation(state.conversation_id)
  end

  defp prewarm_search(state) do
    workspace = state.opts[:working_directory] || state.opts[:workspace_path]

    case Handbeam.Search.prewarm(workspace) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("[Runner] search prewarm failed: #{inspect(reason)}")
    end
  end

  defp job_context_present?(state) do
    dir = state.opts[:working_directory] || state.opts[:workspace_path]
    is_binary(dir) and dir != ""
  end

  defp job_context(state) do
    %{
      conversation_id: state.conversation_id,
      run_id: state.opts[:run_id],
      working_directory: state.opts[:working_directory] || state.opts[:workspace_path]
    }
  end

  defp put_persistence_callback(opts, conversation_id) do
    user_on_event = Keyword.get(opts, :on_event)
    progress = fn kind -> notify_progress_owner({kind, %{}}, opts) end
    opts = Keyword.put(opts, :on_progress, progress)

    Keyword.put(opts, :on_event, fn event ->
      {kind, payload} = event

      # 1. Run extension hooks (may block/transform)
      hook_result =
        if Keyword.get(opts, :delegated?, false),
          do: :ok,
          else: Handbeam.Extension.HookPipeline.run(conversation_id, event)

      case hook_result do
        {:block, reason} ->
          if Handbeam.Extension.Event.blockable?(kind) do
            Logger.debug(
              "[Runner] event blocked by extension hook kind=#{kind} conversation=#{conversation_id} reason=#{reason}"
            )
          else
            Logger.warning(
              "[Runner] extension hook attempted to block read-only event kind=#{kind} conversation=#{conversation_id} reason=#{reason} — ignoring block"
            )

            persist_and_callback(conversation_id, event, opts, user_on_event)
          end

        {:transform, transformed_payload} ->
          if Handbeam.Extension.Event.blockable?(kind) do
            transformed_event = {kind, Map.merge(payload, transformed_payload)}
            persist_and_callback(conversation_id, transformed_event, opts, user_on_event)
          else
            Logger.debug(
              "[Runner] extension hook attempted to transform read-only event kind=#{kind} conversation=#{conversation_id} — ignoring transform"
            )

            persist_and_callback(conversation_id, event, opts, user_on_event)
          end

        :ok ->
          persist_and_callback(conversation_id, event, opts, user_on_event)
      end
    end)
  end

  defp persist_and_callback(conversation_id, event, opts, user_on_event) do
    notify_progress_owner(event, opts)
    track_search_access(event, opts)

    # 2. Normal persistence + session broadcast
    log_runner_event(conversation_id, event)

    case Handbeam.Agent.TranscriptPersistence.handle_event(conversation_id, event, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        dir = Handbeam.ConversationStore.storage_dir()

        raise "Transcript persistence failed: #{inspect(reason)} dir=#{dir} exists=#{File.exists?(Path.join([dir, "items", conversation_id, "meta.json"]))}"
    end

    # 3. User callback (if any)
    if is_function(user_on_event, 1) do
      user_on_event.(event)
    end

    projected = Handbeam.Agent.TranscriptPersistence.project_event(conversation_id, event)
    broadcast_session_event(conversation_id, projected, opts)
  end

  defp track_search_access({:tool_end, payload}, opts) do
    tool = payload[:tool] || payload["tool"]
    path = payload[:file_path] || payload["file_path"]
    workspace = opts[:working_directory] || opts[:workspace_path]
    successful? = is_nil(payload[:error]) and is_nil(payload["error"])
    normalized_tool = if is_binary(tool), do: String.downcase(tool), else: ""

    if successful? and normalized_tool in ["read", "edit", "write"] and
         is_binary(workspace) and is_binary(path) do
      Handbeam.Search.touch(workspace, path)

      if normalized_tool in ["edit", "write"] do
        Handbeam.Search.notify_path(workspace, path)
      end
    end

    :ok
  end

  defp track_search_access(_event, _opts), do: :ok

  defp notify_progress_owner({kind, _payload}, opts) when kind in @progress_events do
    case Keyword.get(opts, :runner_pid) do
      pid when is_pid(pid) -> send(pid, {:run_progress, Keyword.get(opts, :run_id), kind})
      _ -> :ok
    end
  end

  defp notify_progress_owner(_event, _opts), do: :ok

  defp broadcast_session_event(conversation_id, {kind, payload}, opts) do
    payload = stamp_run_id(payload, opts)
    Session.broadcast_event(conversation_id, kind, payload)
  end

  defp stamp_run_id(payload, opts) when is_map(payload) do
    Map.put_new(payload, :run_id, Keyword.get(opts, :run_id))
  end

  defp stamp_run_id(payload, _opts), do: payload

  defp log_runner_event(_conversation_id, {:message_delta, %{chunk: chunk}})
       when is_binary(chunk) do
    :ok
  end

  defp log_runner_event(_conversation_id, {:thinking_delta, _payload}) do
    :ok
  end

  defp log_runner_event(conversation_id, {kind, _payload}) do
    if kind not in [:message_delta, :user_on_chunk] do
      Logger.debug("[Runner] persistence callback #{kind} conversation=#{conversation_id}")
    end
  end

  defp resolve_queue_pid!({:via, Registry, {registry, key}}) do
    case Registry.lookup(registry, key) do
      [{pid, _}] -> pid
      [] -> raise "candidate queue not started for #{inspect(key)}"
    end
  end

  defp call_runner(conversation_id, message) do
    GenServer.call({:via, Registry, {Handbeam.AgentRunRegistry, conversation_id}}, message)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:normal, _} -> {:error, :not_found}
    :exit, reason -> {:error, reason}
  end
end

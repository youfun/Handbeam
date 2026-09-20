defmodule Handbeam.Agent.Runner do
  @moduledoc """
  GenServer owner for one active agent run.

  Runner owns lifecycle state and delegates the expensive agent loop to
  `Handbeam.AgentRunTaskSupervisor` via `Task.Supervisor.async_nolink/2`.
  """

  use GenServer

  require Logger

  alias Handbeam.PubSub.Session

  defstruct [
    :conversation_id,
    :content,
    :opts,
    :queue_pid,
    :task,
    :status,
    :error,
    :result,
    :interrupted_state
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

    state = %__MODULE__{
      conversation_id: conversation_id,
      content: content,
      opts: run_opts,
      queue_pid: queue_pid,
      status: :idle
    }

    case accept_inbound(conversation_id, content, run_opts) do
      :ok ->
        {:ok, state, {:continue, :start_task}}

      {:error, reason} ->
        {:stop, {:inbound_persist_failed, reason}}
    end
  end

  # Accepted new-run inbound (review `task_instructions`) is written here so
  # exclusive RunSupervisor start is the accept gate and the user entry exists
  # before handle_continue starts the provider task.
  defp accept_inbound(conversation_id, content, opts) do
    if persist_accepted_inbound?(opts) do
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

  defp persist_accepted_inbound?(opts) do
    Keyword.get(opts, :persist_inbound?, true) and present_task_instructions?(opts)
  end

  defp present_task_instructions?(opts) do
    case Keyword.get(opts, :task_instructions) do
      text when is_binary(text) -> String.trim(text) != ""
      _ -> false
    end
  end

  @impl true
  def handle_continue(:start_task, state) do
    :ok =
      Session.attach_run(state.conversation_id, self(), state.queue_pid,
        run_id: Keyword.get(state.opts, :run_id),
        workspace_path: Keyword.get(state.opts, :workspace_path),
        model: Keyword.get(state.opts, :model)
      )

    run_opts =
      state.opts
      |> Keyword.put(:candidate_queue, state.queue_pid)
      |> put_persistence_callback(state.conversation_id)

    task =
      Task.Supervisor.async_nolink(Handbeam.AgentRunTaskSupervisor, fn ->
        Handbeam.Agent.run(state.content, run_opts)
      end)

    {:noreply, %{state | status: :running, task: task}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     {:ok,
      %{
        conversation_id: state.conversation_id,
        run_id: Keyword.get(state.opts, :run_id),
        running?: state.status in [:running, :awaiting_approval],
        status: state.status,
        run_pid: self(),
        queue_pid: state.queue_pid,
        error: state.error
      }}, state}
  end

  def handle_call(:cancel, _from, %{status: status, task: task} = state)
      when status in [:running, :awaiting_approval] do
    shutdown_run_task(task)
    persist_cancelled_run(state)
    Handbeam.Agent.CandidateQueue.seal(state.queue_pid)
    Session.broadcast_event(state.conversation_id, :run_end, %{status: "cancelled", turns: 0})
    Session.mark_run_finished(state.conversation_id)
    stop_run_supervisor(state.conversation_id)
    {:reply, :ok, %{state | status: :cancelled, task: nil, interrupted_state: nil}}
  end

  def handle_call(:cancel, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call({:resume, decisions}, _from, %{status: :awaiting_approval} = state) do
    run_opts =
      state.opts
      |> Keyword.put(:candidate_queue, state.queue_pid)
      |> put_persistence_callback(state.conversation_id)

    task =
      Task.Supervisor.async_nolink(Handbeam.AgentRunTaskSupervisor, fn ->
        Handbeam.Agent.resume_after_tool_approval(state.interrupted_state, decisions, run_opts)
      end)

    {:reply, :ok, %{state | status: :running, task: task, interrupted_state: nil}}
  end

  def handle_call({:resume, _decisions}, _from, state) do
    {:reply, {:error, :not_awaiting_approval}, state}
  end

  def handle_call({:enqueue, content, opts}, _from, state) do
    reply = Handbeam.Agent.CandidateQueue.enqueue(state.queue_pid, content, opts)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({ref, {:ok, result}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      %Handbeam.Agent.State{status: :interrupted} = interrupted ->
        {:noreply,
         %{state | status: :awaiting_approval, interrupted_state: interrupted, task: nil}}

      _ ->
        Handbeam.Agent.CandidateQueue.seal(state.queue_pid)
        Session.mark_run_finished(state.conversation_id)

        Task.Supervisor.start_child(Handbeam.AgentRunTaskSupervisor, fn ->
          Handbeam.Threads.Collaboration.completed(state.conversation_id, result, state.opts)
        end)

        stop_run_supervisor(state.conversation_id)
        {:noreply, %{state | status: :completed, result: result, task: nil}}
    end
  end

  def handle_info({ref, {:error, reason}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish_error(state, reason)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    finish_error(state, reason)
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp shutdown_run_task(nil), do: :ok

  defp shutdown_run_task(%Task{} = task) do
    _ = Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp persist_cancelled_run(state) do
    event = {:run_end, %{status: "cancelled", turns: 0}}

    case Handbeam.Agent.TranscriptPersistence.handle_event(
           state.conversation_id,
           event,
           state.opts
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Runner] cancelled run transcript persist failed conversation=#{state.conversation_id} " <>
            "reason=#{inspect(reason)}"
        )
    end
  end

  defp finish_error(state, reason) do
    message = inspect(reason)
    Handbeam.Agent.CandidateQueue.seal(state.queue_pid)

    Session.broadcast_event(state.conversation_id, :run_end, %{
      status: "error",
      turns: 0,
      error: message
    })

    Session.mark_run_finished(state.conversation_id)
    Logger.error("[Runner] Agent run failed: #{message}")
    stop_run_supervisor(state.conversation_id)
    {:noreply, %{state | status: :error, error: reason, task: nil}}
  end

  defp stop_run_supervisor(conversation_id) do
    Task.Supervisor.start_child(Handbeam.AgentRunTaskSupervisor, fn ->
      Handbeam.AgentRunSupervisor.stop_run(conversation_id)
    end)

    :ok
  end

  @blockable_events [:before_agent_start, :tool_call, :context]

  defp put_persistence_callback(opts, conversation_id) do
    user_on_event = Keyword.get(opts, :on_event)

    Keyword.put(opts, :on_event, fn event ->
      {kind, payload} = event

      # 1. Run extension hooks (may block/transform)
      case Handbeam.Extension.HookPipeline.run(conversation_id, event) do
        {:block, reason} ->
          if kind in @blockable_events do
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
          if kind in @blockable_events do
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
    # 2. Normal persistence + session broadcast
    log_runner_event(conversation_id, event)
    Handbeam.Agent.TranscriptPersistence.handle_event(conversation_id, event, opts)

    # 3. User callback (if any)
    if is_function(user_on_event, 1) do
      user_on_event.(event)
    end
  end

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

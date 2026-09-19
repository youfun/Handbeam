defmodule Handbeam.Runtime.TaskTracker do
  @moduledoc """
  Tracks active Runner executions for host notifications.

  One task is one `run_id`. Follow-up messages absorbed by the current
  Runner stay on the same task. `tool_approval_requested` is waiting,
  not ended. Terminal `run_end` is the only completion signal.
  """

  use GenServer

  alias Handbeam.Runtime.Notify
  alias Handbeam.Runtime.NotifyAdapter

  @topic "runtime:tasks"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Handbeam.PubSub, @topic)
  end

  @spec viewing(pid(), String.t() | nil) :: :ok
  def viewing(pid, conversation_id) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:viewing, pid, conversation_id})
  catch
    :exit, _ -> :ok
  end

  @spec snapshot() :: Notify.snapshot()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  catch
    :exit, _ -> Notify.snapshot([])
  end

  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Handbeam.PubSub, "runtime:runs")

    {:ok,
     %{
       tasks: %{},
       viewers: %{}
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, notify_snapshot(state), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | tasks: %{}}}
  end

  @impl true
  def handle_cast({:viewing, pid, conversation_id}, state) do
    Process.monitor(pid)
    {:noreply, put_in(state, [:viewers, pid], conversation_id)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, update_in(state.viewers, &Map.delete(&1, pid))}
  end

  def handle_info({:run_lifecycle, conversation_id, :run_start, payload}, state) do
    task = %{
      conversation_id: conversation_id,
      run_id: resolve_run_id(payload, conversation_id, conversation_id),
      workspace_id: workspace_id(conversation_id),
      title: conversation_title(conversation_id),
      status: :running
    }

    state = put_in(state, [:tasks, conversation_id], task)
    dispatch(state, {:started, task})
    {:noreply, state}
  end

  def handle_info({:run_lifecycle, conversation_id, :tool_approval_requested, payload}, state) do
    {:noreply, put_waiting(state, conversation_id, payload)}
  end

  def handle_info({:run_lifecycle, conversation_id, :run_end, payload}, state) do
    if waiting_status?(payload) do
      {:noreply, put_waiting(state, conversation_id, payload)}
    else
      {:noreply, finish_task(state, conversation_id, payload, end_reason(payload))}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp dispatch(state, event) do
    snapshot = notify_snapshot(state)
    Phoenix.PubSub.broadcast(Handbeam.PubSub, @topic, {:runtime_tasks, snapshot})

    context = %{
      app_visible?: NotifyAdapter.app_visible?(),
      viewing?: viewing?(state, event_conversation_id(event))
    }

    Enum.each(Notify.actions(snapshot, event, context), fn action ->
      maybe_broadcast_in_app(action)
      NotifyAdapter.apply(action)
    end)
  end

  defp maybe_broadcast_in_app({:in_app_ended, task, reason}) do
    Phoenix.PubSub.broadcast(Handbeam.PubSub, @topic, {:in_app_ended, task, reason})
  end

  defp maybe_broadcast_in_app(_action), do: :ok

  defp event_conversation_id({:started, task}), do: task.conversation_id
  defp event_conversation_id({:waiting, task}), do: task.conversation_id
  defp event_conversation_id({:ended, task, _reason}), do: task.conversation_id

  defp viewing?(state, conversation_id) do
    Enum.any?(state.viewers, fn {_pid, viewed} -> viewed == conversation_id end)
  end

  defp notify_snapshot(state) do
    state.tasks
    |> Map.values()
    |> Enum.sort_by(& &1.conversation_id)
    |> Notify.snapshot()
  end

  defp put_waiting(state, conversation_id, payload) do
    case Map.get(state.tasks, conversation_id) do
      nil ->
        state

      task ->
        task = %{
          task
          | status: :waiting_confirmation,
            run_id: resolve_run_id(payload, conversation_id, task.run_id)
        }

        state = put_in(state, [:tasks, conversation_id], task)
        dispatch(state, {:waiting, task})
        state
    end
  end

  defp finish_task(state, conversation_id, payload, reason) do
    {task, state} = pop_in(state, [:tasks, conversation_id])

    case task do
      nil ->
        state

      task ->
        task = Map.put(task, :run_id, resolve_run_id(payload, conversation_id, task.run_id))
        dispatch(state, {:ended, task, reason})
        state
    end
  end

  defp resolve_run_id(payload, conversation_id, fallback) do
    payload_value(payload, :run_id) || session_run_id(conversation_id) || fallback
  end

  defp session_run_id(conversation_id) do
    case Handbeam.PubSub.Session.whereis(conversation_id) do
      nil ->
        nil

      _pid ->
        %{meta: meta} = Handbeam.PubSub.Session.snapshot(conversation_id)
        meta[:run_id] || meta["run_id"]
    end
  catch
    :exit, _ -> nil
  end

  defp waiting_status?(payload) do
    to_string(payload_value(payload, :status) || "") in ["interrupted", "awaiting_approval"]
  end

  defp end_reason(payload) do
    case to_string(payload_value(payload, :status) || "completed") do
      "cancelled" -> :cancelled
      "error" -> :failed
      _ -> :completed
    end
  end

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp conversation_title(conversation_id) do
    case Handbeam.ConversationStore.get(conversation_id) do
      {:ok, conversation} -> conversation["title"]
      _ -> nil
    end
  end

  defp workspace_id(conversation_id) do
    case Handbeam.ConversationStore.get(conversation_id) do
      {:ok, conversation} -> conversation["workspace_id"]
      _ -> nil
    end
  end
end

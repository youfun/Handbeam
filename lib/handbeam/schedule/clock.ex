defmodule Handbeam.Schedule.Clock do
  @moduledoc """
  Application-wide single writer for due schedules.

  It claims slots and hands them to `Dispatch`. It does not run the model,
  and it does not decide that a timer firing means the slot is due.
  """

  use GenServer

  alias Handbeam.Schedule.{Dispatch, Notice, Store}

  @max_delay 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec tick(DateTime.t() | nil) :: :ok
  def tick(now \\ nil) do
    GenServer.call(__MODULE__, {:tick, now || Handbeam.Schedule.now()})
  end

  @spec recover(DateTime.t() | nil) :: :ok
  def recover(now \\ nil) do
    GenServer.call(__MODULE__, {:recover, now || Handbeam.Schedule.now()})
  end

  @impl true
  def init(_opts) do
    state = %{timer: nil}

    state =
      if enabled?() do
        recover_unknown(Handbeam.Schedule.now())
        schedule(state)
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:tick, now}, _from, state) do
    cancel(state.timer)
    recover_unknown(now)
    dispatch_due(now)
    {:reply, :ok, schedule(state)}
  end

  def handle_call({:recover, now}, _from, state) do
    recover_unknown(now)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    now = Handbeam.Schedule.now()
    recover_unknown(now)
    dispatch_due(now)
    {:noreply, schedule(%{state | timer: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp dispatch_due(now) do
    Enum.each(Store.due(now), fn entry ->
      case Store.claim(entry, now) do
        {:ok, claim} -> handoff(claim)
        {:error, _reason} -> :ok
      end
    end)
  end

  defp handoff(claim) do
    if Application.get_env(:handbeam, :schedule_dispatch, :async) == :sync do
      Dispatch.run(claim)
    else
      Task.Supervisor.start_child(Handbeam.AgentRunTaskSupervisor, fn ->
        Dispatch.run(claim)
      end)
    end
  end

  defp recover_unknown(now) do
    if schedule_runs?() do
      Store.recover_unknown(now, &run_present?/2)
      |> Enum.each(fn run ->
        case Store.get(run.schedule_id) do
          {:ok, schedule} -> Notice.unknown(schedule, run)
          _ -> :ok
        end
      end)
    else
      :ok
    end
  end

  defp run_present?(conversation_id, run_id) do
    registry_alive?(conversation_id, run_id) or session_running?(conversation_id, run_id)
  end

  defp registry_alive?(conversation_id, run_id) do
    case Registry.lookup(Handbeam.AgentRunRegistry, conversation_id) do
      [{pid, %{run_id: ^run_id, active?: true}}] -> Process.alive?(pid)
      [{pid, %{run_id: ^run_id}}] -> Process.alive?(pid)
      _ -> false
    end
  end

  defp session_running?(conversation_id, run_id) do
    case Handbeam.Agent.Coordinator.status(conversation_id) do
      {:ok, %{running?: true, run_id: ^run_id}} -> true
      _ -> false
    end
  end

  defp schedule(state) do
    if enabled?() do
      %{state | timer: Process.send_after(self(), :tick, delay())}
    else
      %{state | timer: nil}
    end
  end

  defp delay do
    now = Handbeam.Schedule.now()

    case Store.earliest_next_run_at() do
      %DateTime{} = next ->
        diff = DateTime.diff(next, now, :millisecond)
        diff = if diff < 0, do: 0, else: diff
        min(diff, @max_delay)

      _ ->
        @max_delay
    end
  end

  defp cancel(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel(_), do: :ok

  defp enabled? do
    Application.get_env(:handbeam, :schedule_clock, enabled: true)[:enabled] != false
  end

  # A fresh install starts this process before migrations. Missing the table
  # is not a failed recovery.
  defp schedule_runs? do
    query = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'schedule_runs'"

    case Handbeam.Repo.query(query) do
      {:ok, %{rows: [[1]]}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end

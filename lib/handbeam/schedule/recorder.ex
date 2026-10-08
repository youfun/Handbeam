defmodule Handbeam.Schedule.Recorder do
  @moduledoc """
  Writes the terminal status of a scheduled run back to `schedule_runs`.

  `:interrupted` is not terminal. A scheduled run should already have been
  turned into `:halted` before it could wait for a person.
  """

  use GenServer

  alias Handbeam.PubSub.AgentEvent
  alias Handbeam.Schedule.Store

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Handbeam.PubSub, "runtime:runs")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:run_lifecycle, _conversation_id, :run_end, payload}, state) do
    status = payload_value(payload, :status)
    run_id = payload_value(payload, :run_id)

    cond do
      not is_binary(run_id) or run_id == "" ->
        :ok

      status in [:interrupted, "interrupted", :awaiting_approval, "awaiting_approval"] ->
        :ok

      AgentEvent.terminal_status?(status) ->
        Store.finish_by_run_id(run_id, map_status(status), reason(payload, status))

      true ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp map_status(status) when status in [:completed, "completed"], do: "completed"
  defp map_status(status) when status in [:cancelled, "cancelled"], do: "cancelled"
  defp map_status(status) when status in [:stalled, "stalled"], do: "stalled"
  defp map_status(status) when status in [:halted, "halted"], do: "halted"
  defp map_status(_status), do: "failed"

  defp reason(payload, status) do
    case payload_value(payload, :error) do
      value when is_binary(value) and value != "" -> value
      _ -> to_string(status)
    end
  end

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp payload_value(_payload, _key), do: nil
end

defmodule Handbeam.Schedule do
  @moduledoc false

  @doc """
  Clock used by schedule writes.

  Tests inject `{:handbeam, :schedule_now}` so a save does not read the wall clock.
  """
  @spec now() :: DateTime.t()
  def now do
    case Application.get_env(:handbeam, :schedule_now) do
      fun when is_function(fun, 0) -> truncate(fun.())
      _ -> DateTime.utc_now() |> truncate()
    end
  end

  defp truncate(%DateTime{} = dt), do: DateTime.truncate(dt, :second)
  defp truncate(other), do: other

  @doc "Tell open conversations that a schedule row changed."
  @spec notify(String.t() | nil) :: :ok
  def notify(conversation_id) when is_binary(conversation_id) do
    Phoenix.PubSub.broadcast(
      Handbeam.PubSub,
      "runtime:schedules",
      {:schedule_changed, conversation_id}
    )

    :ok
  end

  def notify(_conversation_id), do: :ok
end

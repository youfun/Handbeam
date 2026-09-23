defmodule Handbeam.Delivery.Noop do
  @moduledoc "Default delivery adapter. It intentionally performs no external IO."

  @behaviour Handbeam.Delivery

  @impl true
  def deliver(_entry, _opts), do: :ok
end

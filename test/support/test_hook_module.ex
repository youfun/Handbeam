defmodule TestHookModule do
  @moduledoc false
  @behaviour Handbeam.Extension.Hook

  alias Handbeam.Extension.Event

  @impl true
  def handle_event(%Event{}, _ctx) do
    :ok
  end
end

defmodule Handbeam.Tool.Builtin.ElixirScriptHangInspect do
  @moduledoc false
  defstruct []
end

defimpl Inspect, for: Handbeam.Tool.Builtin.ElixirScriptHangInspect do
  def inspect(_value, _opts) do
    receive do
      :never -> "%Handbeam.Tool.Builtin.ElixirScriptHangInspect{}"
    end
  end
end

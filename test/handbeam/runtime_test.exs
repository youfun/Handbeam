defmodule Handbeam.RuntimeTest do
  use ExUnit.Case, async: false

  test "cancel_all_runs is a no-op without runners" do
    assert :ok = Handbeam.Runtime.cancel_all_runs()
  end
end

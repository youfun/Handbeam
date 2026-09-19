defmodule Handbeam.RuntimeTest do
  use ExUnit.Case, async: false

  test "cancel_all_runs is a no-op without runners" do
    assert :ok = Handbeam.Runtime.cancel_all_runs()
  end

  test "mark_interrupted_runs is a no-op without sessions" do
    assert :ok = Handbeam.Runtime.mark_interrupted_runs()
  end
end

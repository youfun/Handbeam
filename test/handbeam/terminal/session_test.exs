defmodule Handbeam.Terminal.SessionTest do
  use ExUnit.Case, async: false

  alias Handbeam.Terminal.Registry

  setup_all do
    unless Process.whereis(Registry) do
      {:ok, _} = Registry.start_link()
    end

    :ok
  end

  describe "Registry" do
    test "registers and looks up sessions" do
      test_pid = self()
      :ok = Registry.register("ws1", "term-a", test_pid)
      {:ok, ^test_pid} = Registry.lookup("ws1", "term-a")
    end

    test "rejects duplicate names in same workspace" do
      test_pid = self()
      :ok = Registry.register("ws2", "dup", test_pid)
      assert {:error, :already_exists} = Registry.register("ws2", "dup", test_pid)
    end

    test "allows same name in different workspaces" do
      p1 = spawn(fn -> Process.sleep(:infinity) end)
      p2 = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Registry.register("ws-a", "term", p1)
      :ok = Registry.register("ws-b", "term", p2)
    end

    test "lists terminals by workspace" do
      p1 = spawn(fn -> Process.sleep(:infinity) end)
      p2 = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Registry.register("ws-list", "one", p1)
      :ok = Registry.register("ws-list", "two", p2)
      :ok = Registry.register("ws-other", "three", self())

      list = Registry.list("ws-list")
      names = Enum.map(list, & &1.name)
      assert "one" in names
      assert "two" in names
      refute "three" in names
    end

    test "unregisters by name" do
      :ok = Registry.register("ws-unreg", "t", self())
      :ok = Registry.unregister("ws-unreg", "t")
      assert {:error, :not_found} = Registry.lookup("ws-unreg", "t")
    end

    test "auto-unregisters on process death" do
      dying_pid =
        spawn(fn ->
          receive do
            :die -> :ok
          end
        end)

      :ok = Registry.register("ws-auto", "dying", dying_pid)
      {:ok, ^dying_pid} = Registry.lookup("ws-auto", "dying")

      Process.exit(dying_pid, :kill)
      Process.sleep(100)

      assert {:error, :not_found} = Registry.lookup("ws-auto", "dying")
    end

    test "remove_workspace clears all terminals for a workspace" do
      :ok = Registry.register("ws-clear", "a", self())
      :ok = Registry.register("ws-clear", "b", self())
      :ok = Registry.remove_workspace("ws-clear")
      assert Registry.list("ws-clear") == []
    end
  end
end

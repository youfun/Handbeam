defmodule Handbeam.ConversationStoreInternalTest do
  use ExUnit.Case, async: false
  alias Handbeam.ConversationStore

  setup do
    old_home = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "internal-store-#{Ecto.UUID.generate()}")
    System.put_env("HOME", home)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      File.rm_rf!(home)
    end)

    :ok
  end

  test "legacy visibility and index recovery retain internal relationships" do
    {:ok, user} = ConversationStore.create("ws")

    {:ok, child} =
      ConversationStore.create("ws",
        visibility: "internal",
        parent_conversation_id: user["id"],
        parent_run_id: "run",
        parent_tool_call_id: "call"
      )

    assert ConversationStore.list_for_workspace("ws") == [user]

    assert {:error, :not_found} =
             ConversationStore.get(child["id"],
               parent_conversation_id: user["id"],
               workspace_id: "ws"
             )

    File.rm!(ConversationStore.index_path())
    assert {:ok, _} = ConversationStore.update_meta(user["id"], title: "updated")
    {:ok, index} = ConversationStore.index_path() |> File.read!() |> Handbeam.JSON.decode()
    entry = Enum.find(index["conversations"], &(&1["id"] == child["id"]))
    assert entry["visibility"] == "internal"
    assert entry["parent_run_id"] == "run"
    assert entry["parent_tool_call_id"] == "call"
    assert length(ConversationStore.list(include_internal?: true)) == 2

    assert {:ok, _} =
             ConversationStore.upsert(
               Map.drop(
                 child,
                 ~w(visibility parent_conversation_id parent_run_id parent_tool_call_id)
               )
             )

    assert ConversationStore.internal?(child["id"])
    assert length(ConversationStore.list()) == 1
  end
end

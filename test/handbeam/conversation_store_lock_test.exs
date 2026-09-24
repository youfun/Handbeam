defmodule Handbeam.ConversationStoreLockTest do
  @moduledoc """
  Failure list: another VM owns `.handbeam-storage.lock` for the conversation root.

  | Input (while locked)       | Expected                                  |
  |----------------------------|-------------------------------------------|
  | `get_meta/1`               | `{:error, :locked}`, not `:corrupted`     |
  | `update_meta/2`            | `{:error, :locked}`                       |
  | `upsert/1`                 | `{:error, :locked}`, no index rebuild     |
  | `list/0`                   | `[]`, no raise                            |

  Invariant: no call changes meta.json or index.json bytes while the lock is
  held elsewhere, and the store works normally once the lock is released.
  """
  use ExUnit.Case, async: false

  alias Handbeam.ConversationStore

  setup do
    home = Path.join(System.tmp_dir!(), "sigil_conversation_lock_#{Ecto.UUID.generate()}")
    original_home = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
      File.rm_rf!(home)
    end)

    root = ConversationStore.storage_dir()
    id = "conv-locked"
    meta_path = Path.join([root, "items", id, "meta.json"])
    index_path = Path.join(root, "index.json")
    File.mkdir_p!(Path.dirname(meta_path))

    meta = %{
      "id" => id,
      "workspace_id" => "ws",
      "title" => "Original",
      "delegated_usage" => %{"child-run" => %{"input_tokens" => 7}},
      "updated_at" => "2026-01-01T00:00:00Z"
    }

    File.write!(meta_path, Jason.encode!(meta))

    File.write!(
      index_path,
      Jason.encode!(%{"conversations" => [Map.take(meta, ["id", "title"])]})
    )

    {:ok, lock} = :handbeam_storage.lock(Path.join(root, ".handbeam-storage.lock"))
    on_exit(fn -> :handbeam_storage.close(lock) end)

    %{id: id, lock: lock, meta_path: meta_path, index_path: index_path}
  end

  test "locked storage is reported as locked and never rewritten", ctx do
    meta_bytes = File.read!(ctx.meta_path)
    index_bytes = File.read!(ctx.index_path)

    assert {:error, :locked} = ConversationStore.get_meta(ctx.id)
    assert {:error, :locked} = ConversationStore.update_meta(ctx.id, title: "Changed")

    assert {:error, :locked} =
             ConversationStore.upsert(%{"id" => ctx.id, "workspace_id" => "ws", "title" => "X"})

    assert ConversationStore.list() == []

    assert File.read!(ctx.meta_path) == meta_bytes
    assert File.read!(ctx.index_path) == index_bytes

    assert :ok = :handbeam_storage.close(ctx.lock)

    assert {:ok, %{"title" => "Changed"} = meta} =
             ConversationStore.update_meta(ctx.id, title: "Changed")

    assert meta["delegated_usage"] == %{"child-run" => %{"input_tokens" => 7}}
  end
end

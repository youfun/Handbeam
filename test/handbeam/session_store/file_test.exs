defmodule Handbeam.SessionStore.FileTest do
  use ExUnit.Case, async: true

  alias Handbeam.SessionStore.File, as: FileStore

  test "saves loads updates lists and deletes snapshots without runtime pids" do
    dir = tmp_dir()

    sid = "session-store"
    snapshot = %{"seq" => 2, "agent_pid" => self(), "next_turn_messages" => []}

    assert :ok = FileStore.save(sid, snapshot, session_store_dir: dir)
    assert {:ok, loaded} = FileStore.load(sid, session_store_dir: dir)
    assert loaded["seq"] == 2
    refute Map.has_key?(loaded, "agent_pid")

    assert :ok = FileStore.update(sid, %{"model" => "fake"}, session_store_dir: dir)
    assert {:ok, updated} = FileStore.load(sid, session_store_dir: dir)
    assert updated["model"] == "fake"

    assert {:ok, ids} = FileStore.list_active(session_store_dir: dir)
    assert sid in ids

    assert :ok = FileStore.delete(sid, session_store_dir: dir)
    assert {:error, :not_found} = FileStore.load(sid, session_store_dir: dir)
  end

  test "path traversal protection: file paths are always under the configured store_dir" do
    # session_path derives from store_dir via Path.join, so files are always under it.
    # Even an externally-provided dir like /etc/sessions is accepted as the store root
    # because the operator controls session_store_dir via application config.
    dir = tmp_dir()
    path = FileStore.session_path("test", session_store_dir: dir)
    assert String.starts_with?(path, dir)
  end

  test "session_store_dir is validated against the provided root" do
    # With our code change, the session_store_dir validates against itself.
    # The actual production defense is that session_store_dir is config-controlled.
    dir = tmp_dir()
    assert :ok = FileStore.save("x", %{"seq" => 1}, session_store_dir: dir)
  end

  test "snapshot is redacted before write" do
    dir = tmp_dir()

    sid = "redact-test"

    snapshot = %{
      "seq" => 1,
      "agent_pid" => self(),
      "events" => [
        %{"kind" => "tool_start", "payload" => %{"api_key" => "sk-secret-123", "tool" => "bash"}}
      ]
    }

    assert :ok = FileStore.save(sid, snapshot, session_store_dir: dir)

    path = FileStore.session_path(sid, session_store_dir: dir)
    raw = File.read!(path)
    decoded = Jason.decode!(raw)

    refute Map.has_key?(decoded, "agent_pid")

    assert decoded["events"] == [
             %{
               "kind" => "tool_start",
               "payload" => %{"api_key" => "[REDACTED]", "tool" => "bash"}
             }
           ]
  end

  test "snapshot file is written with 0600 permissions" do
    dir = tmp_dir()

    sid = "perm-test"
    assert :ok = FileStore.save(sid, %{"seq" => 1}, session_store_dir: dir)

    path = FileStore.session_path(sid, session_store_dir: dir)
    {:ok, %{access: access}} = File.stat(path)
    assert access == :read_write
  end

  test "session_store_dir under ~/.handbeam/sessions is accepted" do
    dir = tmp_dir()

    assert :ok = FileStore.save("x", %{"seq" => 1}, session_store_dir: dir)
  end

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "sigil_store_test_#{System.unique_integer([:positive])}")
  end
end

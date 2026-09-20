defmodule Handbeam.StorageLockIntegrationTest do
  use ExUnit.Case, async: false

  alias Handbeam.ConversationTranscriptStore.Journal

  setup do
    root = Path.join(System.tmp_dir!(), "storage-lock-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: Path.join(root, "messages.jsonl")}
  end

  test "an existing OS lock blocks reads and metadata writes without changing bytes", %{
    root: root
  } do
    path = Path.join(root, "meta.json")
    File.write!(path, ~s({"title":"original"}))
    {:ok, lock} = :handbeam_storage.lock(Path.join(root, ".handbeam-storage.lock"))

    assert {:error, :locked} = Journal.read_file(root, path)
    assert {:error, :locked} = Journal.write_json(root, path, %{"title" => "changed"})
    assert File.read!(path) == ~s({"title":"original"})
    assert :ok = :handbeam_storage.close(lock)
    assert :ok = Journal.write_json(root, path, %{"title" => "changed"})
  end

  test "directory aliases share one retained resource and lock sidecar", %{root: root, path: path} do
    alias_root = root <> "-alias"
    File.ln_s!(root, alias_root)
    on_exit(fn -> File.rm!(alias_root) end)
    before_count = map_size(:sys.get_state(Journal).locks)

    assert {:ok, _} = Journal.append(path, %{"id" => "one"})
    assert {:ok, _} = Journal.append(Path.join(alias_root, "other.jsonl"), %{"id" => "two"})
    assert map_size(:sys.get_state(Journal).locks) == before_count + 1
    assert File.exists?(Path.join(root, ".handbeam-storage.lock"))
  end

  test "Journal exit releases retained resources and WAL replays after restart", %{path: path} do
    pending = %{
      "$handbeam_journal" => 1,
      "op" => "append",
      "entry" => %{"id" => "replayed"},
      "txid" => 1
    }

    File.write!(path <> ".pending", Jason.encode!(pending) <> "\n", [:sync])
    assert {:ok, [%{"id" => "replayed"}]} = Journal.load(path)
    lock_path = Path.join(Path.dirname(path), ".handbeam-storage.lock")

    :ok = Supervisor.terminate_child(Handbeam.Supervisor, Journal)
    assert {:ok, lock} = :handbeam_storage.lock(lock_path)
    assert :ok = :handbeam_storage.close(lock)
    {:ok, _} = Supervisor.restart_child(Handbeam.Supervisor, Journal)
    assert {:ok, [%{"id" => "replayed"}]} = Journal.load(path)
  end

  test "ordinary entries with txid survive and malformed journal records fail clearly", %{
    path: path
  } do
    File.write!(path, Jason.encode!(%{"id" => "plain", "txid" => 99}) <> "\n")
    assert {:ok, [%{"id" => "plain", "txid" => 99}]} = Journal.load(path)

    bad_replace = %{"$handbeam_journal" => 1, "op" => "replace", "entries" => [1], "txid" => 1}
    File.write!(path, Jason.encode!(bad_replace) <> "\n")
    :ok = Journal.invalidate(path)
    assert {:error, {:corrupt_journal, 1, :invalid_replace_entries}} = Journal.load(path)
  end
end

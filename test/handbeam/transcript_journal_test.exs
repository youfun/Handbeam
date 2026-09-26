defmodule Handbeam.TranscriptJournalTest do
  use ExUnit.Case, async: false

  alias Handbeam.ConversationTranscriptStore.Journal

  setup do
    root = Path.join(System.tmp_dir!(), "journal-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{path: Path.join(root, "messages.jsonl")}
  end

  test "large replacements compact immediately rather than accumulating full snapshots", %{
    path: path
  } do
    entries = for n <- 1..300, do: %{"id" => "id-#{n}"}
    assert :ok = Journal.replace(path, entries)
    records = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert length(records) == 301
    assert hd(records) == %{"id" => "id-1"}
    assert List.last(records)["op"] == "checkpoint"
    assert :ok = Journal.replace(path, [%{"id" => "last"}])
    Journal.invalidate(path)
    assert {:ok, %{"sequence" => 301}} = Journal.append(path, %{"id" => "new"})
  end

  test "legacy revisions and ordinary txid fields do not poison new transaction IDs", %{
    path: path
  } do
    records = [
      %{"id" => "old", "content" => "a", "txid" => "user-metadata"},
      %{
        "$handbeam_journal" => 1,
        "op" => "update",
        "id" => "old",
        "patch" => %{"content" => %{"$append" => "b"}}
      }
    ]

    File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")
    assert {:ok, [%{"content" => "ab"}]} = Journal.load(path)

    assert {:ok, %{"content" => "abc"}} =
             Journal.update(path, "old", %{"content" => %{"$append" => "c"}}, "now")

    Journal.invalidate(path)
    assert {:ok, [%{"content" => "abc"}]} = Journal.load(path)
  end

  test "invalid replacements do not leave a poisoned retry intent", %{path: path} do
    assert {:ok, _} = Journal.append(path, %{"id" => "safe"})
    assert {:error, :invalid_replace_entries} = Journal.replace(path, [1])
    refute File.exists?(path <> ".pending")
    assert {:ok, [%{"id" => "safe"}]} = Journal.load(path)
  end

  test "failed first mutation retains its storage lock", %{path: path} do
    assert {:error, :not_found} = Journal.update(path, "absent", %{}, "now")

    assert {:error, :locked} =
             :handbeam_storage.lock(Path.join(Path.dirname(path), ".handbeam-storage.lock"))

    assert {:ok, _} = Journal.append(path, %{"id" => "present"})
  end

  test "compaction preserves sequence high-water mark and page cursors", %{path: path} do
    for n <- 1..7 do
      assert {:ok, _} = Journal.append(path, %{"id" => "id-#{n}", "content" => "#{n}"})
    end

    assert {:ok, %{entries: page, before: "id-6", has_more?: true}} =
             Journal.page(path, limit: 2)

    assert Enum.map(page, & &1["id"]) == ["id-6", "id-7"]
    :ok = Journal.delete(path, "id-4")
    :ok = Journal.delete(path, "id-7")

    # Exactly 256 revisions triggers compaction, independently of the seven appends.
    for _ <- 1..254 do
      assert {:ok, _} = Journal.update(path, "id-1", %{"content" => %{"$append" => "x"}}, "now")
    end

    assert length(String.split(File.read!(path), "\n", trim: true)) == 6
    :ok = Journal.invalidate(path)
    assert {:ok, [first | _]} = Journal.load(path)
    assert first["content"] == "1" <> String.duplicate("x", 254)
    assert {:ok, %{"sequence" => 8}} = Journal.append(path, %{"id" => "id-8"})
    assert {:ok, %{entries: older, before: "id-3"}} = Journal.page(path, limit: 2, before: "id-6")
    assert Enum.map(older, & &1["id"]) == ["id-3", "id-5"]

    assert {:ok, %{entries: oldest, has_more?: false}} =
             Journal.page(path, limit: 2, before: "id-3")

    assert Enum.map(oldest, & &1["id"]) == ["id-1", "id-2"]
    assert {:error, :invalid_cursor} = Journal.page(path, before: "id-7")
    assert {:error, :invalid_limit} = Journal.page(path, limit: 201)
  end

  test "a synced pending delta survives restart and cannot be replayed twice", %{path: path} do
    File.write!(path, Jason.encode!(%{"id" => "reply", "content" => "prefix"}) <> "\n")

    pending = %{
      "$handbeam_journal" => 1,
      "op" => "update",
      "id" => "reply",
      "patch" => %{"content" => %{"$append" => " 中文-tail"}},
      "txid" => 1
    }

    encoded = Jason.encode!(pending) <> "\n"
    File.write!(path <> ".pending", encoded, [:sync])
    :ok = Supervisor.terminate_child(Handbeam.Supervisor, Journal)
    {:ok, _} = Supervisor.restart_child(Handbeam.Supervisor, Journal)

    assert {:ok, [%{"content" => "prefix 中文-tail"}]} = Journal.load(path)
    refute File.exists?(path <> ".pending")

    # Crash after writing the log but before clearing the intent, or a stale
    # intent reappearing after later successful transactions, must be harmless.
    assert {:ok, _} = Journal.update(path, "reply", %{"content" => %{"$append" => "!"}}, "now")
    File.write!(path <> ".pending", encoded, [:sync])
    :ok = Journal.invalidate(path)
    assert {:ok, [%{"content" => "prefix 中文-tail!"}]} = Journal.load(path)
    refute File.exists?(path <> ".pending")
  end

  test "failed replay retains intent and the background retry drains it", %{path: path} do
    pending = %{
      "$handbeam_journal" => 1,
      "op" => "append",
      "entry" => %{"id" => "reply", "content" => "saved intent"},
      "txid" => 1
    }

    File.write!(path <> ".pending", Jason.encode!(pending) <> "\n", [:sync])
    File.mkdir!(path)
    assert {:error, :eisdir} = Journal.load(path)
    assert File.exists?(path <> ".pending")
    File.rmdir!(path)

    # Trigger the same mailbox event as the timer; no timing sleeps or retry loop.
    send(Journal, :retry_pending)
    :sys.get_state(Journal)
    refute File.exists?(path <> ".pending")
    assert {:ok, [%{"content" => "saved intent"}]} = Journal.load(path)
  end

  test "pending delta deduplication survives a compacted checkpoint", %{path: path} do
    {:ok, _} = Journal.append(path, %{"id" => "reply", "content" => "base"})

    for _ <- 1..256 do
      {:ok, _} = Journal.update(path, "reply", %{"content" => %{"$append" => "a"}}, "now")
    end

    stale = %{
      "$handbeam_journal" => 1,
      "op" => "update",
      "id" => "reply",
      "txid" => 2,
      "patch" => %{"content" => %{"$append" => "a"}}
    }

    File.write!(path <> ".pending", Jason.encode!(stale) <> "\n", [:sync])
    Journal.invalidate(path)
    assert {:ok, [%{"content" => content}]} = Journal.load(path)
    assert content == "base" <> String.duplicate("a", 256)
  end
end

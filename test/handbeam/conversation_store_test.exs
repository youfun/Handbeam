defmodule Handbeam.ConversationStoreTest do
  use ExUnit.Case, async: false

  alias Handbeam.ConversationStore

  setup do
    test_id = System.unique_integer([:positive])
    home_dir = Path.join(System.tmp_dir!(), "sigil_conversation_store_home_#{test_id}")
    original_home = System.get_env("HOME")
    System.put_env("HOME", home_dir)

    storage_dir = ConversationStore.storage_dir()

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
      if File.exists?(home_dir), do: File.rm_rf!(home_dir)
    end)

    {:ok, storage_dir: storage_dir, storage_path: ConversationStore.storage_path()}
  end

  # ── Path helpers ────────────────────────────────────────────────────────

  describe "storage_dir/0, index_path/0, paths" do
    test "storage_dir is fixed under ~/.handbeam/conversations", %{storage_dir: storage_dir} do
      assert String.ends_with?(storage_dir, "/.handbeam/conversations")
      assert File.dir?(storage_dir) or not File.exists?(storage_dir)
    end

    test "storage_path returns the index file path", %{storage_path: storage_path} do
      assert String.ends_with?(storage_path, "index.json")
    end

    test "index_path is inside storage_dir", %{storage_dir: storage_dir} do
      index = ConversationStore.index_path()
      assert String.starts_with?(index, storage_dir)
      assert String.ends_with?(index, "index.json")
    end

    test "item_path returns conversation directory (not a .json file)" do
      path = ConversationStore.item_path("conv-abc")
      assert String.contains?(path, "/items/")
      refute String.ends_with?(path, ".json")
      assert String.ends_with?(path, "/conv-abc")
    end

    test "conversation_dir returns directory under items/" do
      dir = ConversationStore.conversation_dir("conv-abc")
      assert String.contains?(dir, "/items/conv-abc")
      refute String.ends_with?(dir, ".json")
    end

    test "meta_path returns meta.json inside conversation dir" do
      path = ConversationStore.meta_path("conv-meta")
      assert String.contains?(path, "/items/conv-meta/meta.json")
    end

    test "messages_path returns messages.jsonl inside conversation dir" do
      path = ConversationStore.messages_path("conv-msg")
      assert String.contains?(path, "/items/conv-msg/messages.jsonl")
    end

    test "files_path returns files.json inside conversation dir" do
      path = ConversationStore.files_path("conv-files")
      assert String.contains?(path, "/items/conv-files/files.json")
    end

    test "paths are stable for same id" do
      p1 = ConversationStore.meta_path("conv-123")
      p2 = ConversationStore.meta_path("conv-123")
      assert p1 == p2
    end
  end

  # ── create ──────────────────────────────────────────────────────────────

  describe "create/2" do
    test "creates conversation directory with meta.json, messages.jsonl, files.json", context do
      {:ok, conversation} =
        ConversationStore.create("ws_1",
          title: "Test chat",
          timeline: [
            %{
              "id" => "msg-1",
              "content_type" => "user_msg",
              "role" => "user",
              "content" => "hello"
            }
          ]
        )

      id = conversation["id"]

      # Directory exists
      conv_dir = ConversationStore.conversation_dir(id)
      assert File.dir?(conv_dir)

      # meta.json exists and contains metadata (no timeline)
      meta_path = ConversationStore.meta_path(id)
      assert File.exists?(meta_path)
      meta_json = File.read!(meta_path) |> Jason.decode!()
      assert meta_json["id"] == id
      assert meta_json["title"] == "Test chat"
      assert meta_json["workspace_id"] == "ws_1"
      refute Map.has_key?(meta_json, "timeline")

      # Physical journal records are replayed into the public history.
      msg_path = ConversationStore.messages_path(id)
      assert File.exists?(msg_path)
      assert {:ok, [entry]} = ConversationStore.load_messages_result(id)
      assert entry["content"] == "hello"
      assert entry["id"] == "msg-1"

      # files.json exists
      files_path = ConversationStore.files_path(id)
      assert File.exists?(files_path)
      files_json = File.read!(files_path) |> Jason.decode!()
      assert files_json["editor_files"] == []
      assert files_json["active_file"] == nil

      # index.json exists and does NOT contain timeline/editor_files/active_file/file_preview_error
      assert File.exists?(context.storage_path)
      index_json = File.read!(context.storage_path) |> Jason.decode!()
      [idx_entry] = index_json["conversations"]
      assert idx_entry["id"] == id
      refute Map.has_key?(idx_entry, "timeline")
      refute Map.has_key?(idx_entry, "editor_files")
      refute Map.has_key?(idx_entry, "active_file")
      refute Map.has_key?(idx_entry, "file_preview_error")
    end

    test "returns created conversation with full fields" do
      {:ok, conversation} =
        ConversationStore.create("ws_1", title: "My Chat")

      assert conversation["workspace_id"] == "ws_1"
      assert conversation["title"] == "My Chat"
      assert conversation["title_source"] == "manual"
      assert is_binary(conversation["id"])
      assert conversation["timeline"] == []
    end

    test "journal projects an empty history when no timeline" do
      {:ok, conversation} = ConversationStore.create("ws_empty")
      id = conversation["id"]

      msg_path = ConversationStore.messages_path(id)
      assert File.exists?(msg_path)
      assert {:ok, []} = ConversationStore.load_messages_result(id)
    end
  end

  # ── list / list_for_workspace ───────────────────────────────────────────

  describe "list/0 and list_for_workspace/1,2" do
    test "returns full conversations with timeline", %{storage_dir: _dir} do
      {:ok, c1} =
        ConversationStore.create("ws_a",
          title: "Chat A",
          timeline: [%{"id" => "t1", "role" => "user", "content" => "hi"}]
        )

      {:ok, _c2} =
        ConversationStore.create("ws_b",
          title: "Chat B",
          timeline: [%{"id" => "t2", "role" => "assistant", "content" => "hello"}]
        )

      all = ConversationStore.list()
      assert length(all) == 2

      ws_a = ConversationStore.list_for_workspace("ws_a")
      assert length(ws_a) == 1
      assert hd(ws_a)["id"] == c1["id"]
      assert [%{"content" => "hi"}] = hd(ws_a)["timeline"]
    end

    test "item directory missing → falls back to index metadata", %{storage_dir: _dir} do
      # Create a conversation normally, then delete its entire item directory
      {:ok, conv} = ConversationStore.create("ws_x", title: "Ghost")
      File.rm_rf!(ConversationStore.conversation_dir(conv["id"]))

      # list/0 should still return it (using index metadata)
      all = ConversationStore.list()
      assert length(all) == 1
      assert hd(all)["id"] == conv["id"]
      assert hd(all)["title"] == "Ghost"
      # Fallback values
      assert hd(all)["timeline"] == []
    end

    test "include_archived? option" do
      {:ok, conv} = ConversationStore.create("ws_a", title: "ToArchive")
      {:ok, _} = ConversationStore.archive(conv["id"])

      assert ConversationStore.list_for_workspace("ws_a") == []
      assert length(ConversationStore.list_for_workspace("ws_a", include_archived?: true)) == 1
    end
  end

  # ── get ─────────────────────────────────────────────────────────────────

  describe "get/1" do
    test "reads single conversation from separate files, returns full map" do
      {:ok, conv} =
        ConversationStore.create("ws_1",
          title: "Direct Read",
          timeline: [
            %{"id" => "msg-1", "content_type" => "user_msg", "role" => "user", "content" => "hi"}
          ],
          editor_files: [%{path: "/tmp/a.ex", name: "a.ex"}],
          active_file: "/tmp/a.ex",
          file_preview_error: nil
        )

      {:ok, read} = ConversationStore.get(conv["id"])

      assert read["id"] == conv["id"]
      assert read["title"] == "Direct Read"
      # timeline loaded from messages.jsonl
      assert [%{"content" => "hi"}] = read["timeline"]
      # editor files loaded from files.json
      assert [%{"path" => "/tmp/a.ex"}] = read["editor_files"]
      assert read["active_file"] == "/tmp/a.ex"
      assert read["file_preview_error"] == nil
    end

    test "returns {:error, :not_found} for missing id" do
      assert {:error, :not_found} = ConversationStore.get("nonexistent-id")
    end

    test "returns full conversation even when messages.jsonl is missing" do
      {:ok, conv} = ConversationStore.create("ws_orphan", title: "Orphan Messages")
      File.rm!(ConversationStore.messages_path(conv["id"]))

      {:ok, read} = ConversationStore.get(conv["id"])
      assert read["id"] == conv["id"]
      assert read["timeline"] == []
    end
  end

  # ── upsert ──────────────────────────────────────────────────────────────

  describe "upsert/1" do
    test "replaces conversation files and syncs index" do
      {:ok, conversation} = ConversationStore.create("ws_1")

      updated =
        Map.put(conversation, "timeline", [
          %{
            "id" => "a1",
            "content_type" => "assistant_msg",
            "role" => "assistant",
            "content" => "hi"
          },
          %{"id" => "t1", "content_type" => "tool", "tool" => "read", "status" => "done"}
        ])

      assert {:ok, _} = ConversationStore.upsert(updated)

      # Verify via get
      {:ok, saved} = ConversationStore.get(conversation["id"])
      assert saved["id"] == conversation["id"]
      assert [%{"content" => "hi"}, %{"tool" => "read"}] = saved["timeline"]

      # Index must NOT contain timeline/editor_files/active_file/file_preview_error
      index_json =
        File.read!(ConversationStore.index_path()) |> Jason.decode!()

      [idx_entry] = index_json["conversations"]
      assert idx_entry["id"] == conversation["id"]
      refute Map.has_key?(idx_entry, "timeline")
      refute Map.has_key?(idx_entry, "editor_files")
      refute Map.has_key?(idx_entry, "active_file")
      refute Map.has_key?(idx_entry, "file_preview_error")

      # meta.json must NOT contain timeline
      meta_json =
        File.read!(ConversationStore.meta_path(conversation["id"])) |> Jason.decode!()

      refute Map.has_key?(meta_json, "timeline")

      assert {:ok, entries} = ConversationStore.load_messages_result(conversation["id"])
      assert entries == updated["timeline"]
    end

    test "upsert preserves title_source field" do
      {:ok, conv} = ConversationStore.create("ws_1", title: "Original", title_source: "auto")

      updated = Map.put(conv, "title", "Renamed")
      assert {:ok, saved} = ConversationStore.upsert(updated)
      assert saved["title"] == "Renamed"
      assert saved["title_source"] == "auto"

      # meta.json should have updated title
      meta_json =
        File.read!(ConversationStore.meta_path(conv["id"])) |> Jason.decode!()

      assert meta_json["title"] == "Renamed"
      assert meta_json["title_source"] == "auto"
    end

    test "upsert updates updated_at" do
      {:ok, conv} = ConversationStore.create("ws_1")

      stale_timestamp = "2000-01-01T00:00:00Z"

      updated =
        conv
        |> Map.put("updated_at", stale_timestamp)
        |> Map.put("timeline", [%{"id" => "u1", "role" => "user", "content" => "later"}])

      assert {:ok, saved} = ConversationStore.upsert(updated)

      assert saved["updated_at"] != stale_timestamp
    end

    test "upsert with empty timeline does not erase existing messages" do
      {:ok, conv} =
        ConversationStore.create("ws_keep",
          timeline: [%{"id" => "m1", "role" => "user", "content" => "keep me"}]
        )

      id = conv["id"]
      msgs_before = File.read!(ConversationStore.messages_path(id))

      updated =
        conv
        |> Map.put("title", "Metadata only")
        |> Map.put("timeline", [])

      assert {:ok, _saved} = ConversationStore.upsert(updated)

      msgs_after = File.read!(ConversationStore.messages_path(id))
      assert msgs_after == msgs_before

      assert {:ok, full} = ConversationStore.get(id)
      assert full["title"] == "Metadata only"
      assert [%{"content" => "keep me"}] = full["timeline"]
    end

    test "upsert rebuilds missing index from existing item metadata" do
      {:ok, conv_a} = ConversationStore.create("ws_1", title: "A")
      {:ok, conv_b} = ConversationStore.create("ws_1", title: "B")

      File.rm!(ConversationStore.index_path())

      assert {:ok, _saved} =
               conv_b
               |> Map.put("title", "B edited")
               |> ConversationStore.upsert()

      ids =
        ConversationStore.index_path()
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("conversations")
        |> Enum.map(& &1["id"])

      assert conv_a["id"] in ids
      assert conv_b["id"] in ids
    end

    test "upsert repairs index reset to only the edited conversation" do
      {:ok, conv_a} = ConversationStore.create("ws_1", title: "A")
      {:ok, conv_b} = ConversationStore.create("ws_1", title: "B")

      reset_index = %{
        "conversations" => [
          %{
            "id" => conv_b["id"],
            "workspace_id" => conv_b["workspace_id"],
            "title" => conv_b["title"],
            "title_source" => conv_b["title_source"],
            "archived_at" => conv_b["archived_at"],
            "created_at" => conv_b["created_at"],
            "updated_at" => conv_b["updated_at"]
          }
        ]
      }

      File.write!(ConversationStore.index_path(), Jason.encode!(reset_index))

      assert {:ok, _saved} =
               conv_b
               |> Map.put("title", "B edited again")
               |> ConversationStore.upsert()

      entries =
        ConversationStore.index_path()
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("conversations")

      assert Enum.any?(entries, &(&1["id"] == conv_a["id"]))
      assert Enum.any?(entries, &(&1["id"] == conv_b["id"] and &1["title"] == "B edited again"))
    end

    test "upsert writes editor_files to files.json" do
      {:ok, conv} = ConversationStore.create("ws_ed")

      updated =
        conv
        |> Map.put("editor_files", [%{path: "/tmp/x.ex", name: "x.ex"}])
        |> Map.put("active_file", "/tmp/x.ex")

      assert {:ok, _} = ConversationStore.upsert(updated)

      files_json =
        File.read!(ConversationStore.files_path(conv["id"])) |> Jason.decode!()

      assert files_json["editor_files"] == [%{"path" => "/tmp/x.ex", "name" => "x.ex"}]
      assert files_json["active_file"] == "/tmp/x.ex"
    end
  end

  # ── archive / unarchive ─────────────────────────────────────────────────

  describe "archive/1 and unarchive/1" do
    test "archive syncs meta and index" do
      {:ok, conversation} =
        ConversationStore.create("ws_1",
          title: "Archivable",
          timeline: [%{"id" => "x1", "role" => "user", "content" => "keep me"}]
        )

      assert {:ok, archived} = ConversationStore.archive(conversation["id"])
      assert is_binary(archived["archived_at"])

      # Default list excludes archived
      assert ConversationStore.list_for_workspace("ws_1") == []

      # Archived still visible with option
      assert [v] = ConversationStore.list_for_workspace("ws_1", include_archived?: true)
      assert v["id"] == conversation["id"]

      # Index entry should reflect archived_at
      index_json =
        File.read!(ConversationStore.index_path()) |> Jason.decode!()

      [idx_entry] = index_json["conversations"]
      assert is_binary(idx_entry["archived_at"])

      # meta.json should reflect archived_at
      meta_json =
        File.read!(ConversationStore.meta_path(conversation["id"])) |> Jason.decode!()

      assert is_binary(meta_json["archived_at"])

      # messages.jsonl should still contain the timeline
      msg_content = File.read!(ConversationStore.messages_path(conversation["id"]))
      assert msg_content =~ "keep me"
    end

    test "unarchive restores conversation" do
      {:ok, conversation} = ConversationStore.create("ws_1", title: "ToRestore")
      ConversationStore.archive(conversation["id"])

      assert {:ok, unarchived} = ConversationStore.unarchive(conversation["id"])
      assert unarchived["archived_at"] == nil

      assert [visible] = ConversationStore.list_for_workspace("ws_1")
      assert visible["id"] == conversation["id"]

      # Index entry should have nil archived_at
      index_json =
        File.read!(ConversationStore.index_path()) |> Jason.decode!()

      [idx_entry] = index_json["conversations"]
      assert is_nil(idx_entry["archived_at"])

      # meta.json should have nil archived_at
      meta_json =
        File.read!(ConversationStore.meta_path(conversation["id"])) |> Jason.decode!()

      assert is_nil(meta_json["archived_at"])
    end
  end

  # ── New message API ─────────────────────────────────────────────────────

  describe "append_message/2" do
    test "appends one line to messages.jsonl without rewriting meta/index" do
      {:ok, conv} =
        ConversationStore.create("ws_ap",
          timeline: [%{"id" => "e1", "role" => "user", "content" => "first"}]
        )

      id = conv["id"]

      # Capture meta/index content before append
      meta_before = File.read!(ConversationStore.meta_path(id))
      index_before = File.read!(ConversationStore.index_path())
      log_before = File.read!(ConversationStore.messages_path(id))

      # Append a message
      :ok =
        ConversationStore.append_message(id, %{
          "id" => "e2",
          "role" => "assistant",
          "content" => "reply"
        })

      # A normal append preserves the existing bytes and adds one durable record.
      log_after = File.read!(ConversationStore.messages_path(id))
      assert String.starts_with?(log_after, log_before)

      appended =
        binary_part(
          log_after,
          byte_size(log_before),
          byte_size(log_after) - byte_size(log_before)
        )

      assert length(String.split(appended, "\n", trim: true)) == 1
      assert {:ok, [_, entry2]} = ConversationStore.load_messages_result(id)
      assert entry2["id"] == "e2"
      assert entry2["content"] == "reply"

      # meta.json should NOT be rewritten (content identical)
      meta_after = File.read!(ConversationStore.meta_path(id))

      assert meta_after == meta_before,
             "append_message should not rewrite meta.json"

      # index.json should NOT be rewritten (content identical)
      index_after = File.read!(ConversationStore.index_path())

      assert index_after == index_before,
             "append_message should not rewrite index.json"
    end

    test "message entries must have an id" do
      {:ok, conv} = ConversationStore.create("ws_ap2")
      id = conv["id"]

      :ok =
        ConversationStore.append_message(id, %{
          "id" => "msg-with-id",
          "role" => "user",
          "content" => "has id"
        })

      loaded = ConversationStore.load_messages(id)
      assert [%{"id" => "msg-with-id"}] = loaded
    end

    test "returns {:error, :not_found} for non-existent conversation" do
      assert {:error, :not_found} =
               ConversationStore.append_message("nonexistent", %{
                 "id" => "x",
                 "role" => "user",
                 "content" => "nope"
               })
    end
  end

  describe "load_messages/1" do
    test "loads messages in file order" do
      {:ok, conv} =
        ConversationStore.create("ws_lm",
          timeline: [
            %{"id" => "1", "role" => "user", "content" => "a"},
            %{"id" => "2", "role" => "assistant", "content" => "b"},
            %{"id" => "3", "role" => "user", "content" => "c"}
          ]
        )

      messages = ConversationStore.load_messages(conv["id"])
      ids = Enum.map(messages, & &1["id"])
      assert ids == ["1", "2", "3"]
    end

    test "does not hide malformed non-tail JSONL records" do
      {:ok, conv} = ConversationStore.create("ws_badline")
      id = conv["id"]

      # Write a malformed line directly into messages.jsonl
      msg_path = ConversationStore.messages_path(id)
      File.write!(msg_path, "this is not json\n{\"id\":\"ok\",\"role\":\"user\"}\n")

      assert {:error, {:corrupt_journal, 1}} = ConversationStore.load_messages_result(id)
    end

    test "returns [] for missing messages.jsonl" do
      assert ConversationStore.load_messages("nonexistent-conv") == []
    end
  end

  describe "replace_messages/2" do
    test "rewrites entire messages.jsonl" do
      {:ok, conv} =
        ConversationStore.create("ws_rp",
          timeline: [
            %{"id" => "old-1", "role" => "user", "content" => "old"}
          ]
        )

      id = conv["id"]

      new_entries = [
        %{"id" => "new-1", "role" => "user", "content" => "fresh"},
        %{"id" => "new-2", "role" => "assistant", "content" => "response"}
      ]

      :ok = ConversationStore.replace_messages(id, new_entries)

      loaded = ConversationStore.load_messages(id)
      assert length(loaded) == 2
      assert Enum.map(loaded, & &1["content"]) == ["fresh", "response"]
    end

    test "returns {:error, :not_found} for non-existent conversation" do
      assert {:error, :not_found} =
               ConversationStore.replace_messages("nonexistent", [
                 %{"id" => "x", "role" => "user", "content" => "nope"}
               ])
    end

    test "normalizes runtime-only values before replacing messages" do
      {:ok, conv} = ConversationStore.create("ws_enc_err")
      id = conv["id"]

      assert :ok =
               ConversationStore.replace_messages(id, [
                 %{"id" => "safe", "role" => "user", "content" => self(), "range" => {0, 0}}
               ])

      [entry] = ConversationStore.load_messages(id)
      assert entry["id"] == "safe"
      assert is_binary(entry["content"])
      assert entry["range"] == [0, 0]
    end
  end

  describe "load_files/1 and save_files/2" do
    test "load_files returns empty defaults when files.json is missing" do
      result = ConversationStore.load_files("nonexistent-conv")
      assert result["editor_files"] == []
      assert result["active_file"] == nil
      assert result["file_preview_error"] == nil
    end

    test "save_files and load_files round-trip" do
      {:ok, conv} = ConversationStore.create("ws_fs")
      id = conv["id"]

      files_data = %{
        "editor_files" => [%{"path" => "/tmp/foo.ex", "name" => "foo.ex"}],
        "active_file" => "/tmp/foo.ex",
        "file_preview_error" => nil
      }

      :ok = ConversationStore.save_files(id, files_data)
      loaded = ConversationStore.load_files(id)
      assert loaded == files_data
    end

    test "save_files returns {:error, :not_found} for non-existent conversation" do
      assert {:error, :not_found} =
               ConversationStore.save_files("nonexistent", %{
                 "editor_files" => [],
                 "active_file" => nil
               })
    end
  end

  describe "token usage" do
    test "records a run once and keeps an older meta total" do
      {:ok, conv} = ConversationStore.create("ws_usage")
      id = conv["id"]

      meta =
        File.read!(ConversationStore.meta_path(id))
        |> Jason.decode!()
        |> Map.put("token_usage", %{
          "input_tokens" => 10,
          "output_tokens" => 2,
          "cache_read_tokens" => 3,
          "cache_write_tokens" => 1
        })

      File.write!(ConversationStore.meta_path(id), Jason.encode!(meta))

      {:ok, legacy} = ConversationStore.get_token_usage(id)
      assert legacy.input_tokens == 10
      assert legacy.total_input_tokens == 14
      refute legacy.usage_incomplete

      :ok =
        ConversationStore.record_run_usage(id, "run-1", %{
          input_tokens: 5,
          output_tokens: 1,
          cache_read_input_tokens: 4,
          total_input_tokens: 9
        })

      :ok =
        ConversationStore.record_run_usage(id, "run-1", %{
          input_tokens: 100,
          output_tokens: 100
        })

      {:ok, usage} = ConversationStore.get_token_usage(id)
      assert usage.input_tokens == 15
      assert usage.output_tokens == 3
      assert usage.cache_read_tokens == 7
      assert usage.total_input_tokens == 23

      {:ok, full} = ConversationStore.get(id)
      assert {:ok, _} = ConversationStore.upsert(Map.put(full, "title", "kept"))
      assert {:ok, ^usage} = ConversationStore.get_token_usage(id)
      assert ConversationStore.get_meta(id) |> elem(1) |> Map.get("title") == "kept"
    end

    test "unknown usage stays marked incomplete" do
      {:ok, conv} = ConversationStore.create("ws_unknown")

      :ok = ConversationStore.record_run_usage(conv["id"], "run-1", %{unknown?: true})

      assert {:ok, %{input_tokens: 0, usage_incomplete: true}} =
               ConversationStore.get_token_usage(conv["id"])
    end

    test "concurrent meta updates do not drop run usage" do
      for _ <- 1..20 do
        {:ok, conv} = ConversationStore.create("ws_race")
        id = conv["id"]

        tasks = [
          Task.async(fn ->
            ConversationStore.update_meta(id, last_run_result: "max_turns")
          end),
          Task.async(fn ->
            ConversationStore.record_run_usage(id, "run-2", %{
              input_tokens: 11,
              output_tokens: 3,
              cache_read_input_tokens: 4,
              total_input_tokens: 15
            })
          end)
        ]

        results = Task.await_many(tasks)

        assert Enum.all?(results, fn
                 :ok -> true
                 {:ok, _} -> true
                 _ -> false
               end)

        {:ok, meta} = ConversationStore.get_meta(id)
        assert meta["last_run_result"] == "max_turns"
        assert meta["run_usage"]["run-2"]["input_tokens"] == 11

        assert {:ok, %{input_tokens: 11, total_input_tokens: 15}} =
                 ConversationStore.get_token_usage(id)
      end
    end

    test "rebuild_token_usage_from_events replaces totals without reading the home directory" do
      {:ok, conv} = ConversationStore.create("ws_rebuild")
      id = conv["id"]
      :ok = ConversationStore.add_token_usage(id, %{input_tokens: 999, output_tokens: 999})

      events = [
        %{
          "kind" => "run_end",
          "payload" => %{
            "status" => "interrupted",
            "run_id" => "run-1",
            "usage" => %{"input_tokens" => 50, "output_tokens" => 5}
          }
        },
        %{
          "kind" => "run_end",
          "payload" => %{
            "status" => "completed",
            "run_id" => "run-1",
            "usage" => %{"input_tokens" => 8, "output_tokens" => 1, "total_input_tokens" => 8}
          }
        },
        %{
          "kind" => "run_end",
          "payload" => %{
            "status" => "max_turns",
            "run_id" => "run-2",
            "usage" => %{"input_tokens" => 2, "output_tokens" => 2}
          }
        }
      ]

      assert :ok = ConversationStore.rebuild_token_usage_from_events(id, events)
      assert :ok = ConversationStore.rebuild_token_usage_from_events(id, events)

      assert {:ok, %{input_tokens: 10, output_tokens: 3, total_input_tokens: 10}} =
               ConversationStore.get_token_usage(id)
    end
  end

  describe "update_meta/2" do
    test "updates meta.json and index.json without touching messages.jsonl" do
      {:ok, conv} =
        ConversationStore.create("ws_um",
          title: "Original Title",
          timeline: [%{"id" => "m1", "role" => "user", "content" => "keep me"}]
        )

      id = conv["id"]

      # Capture messages content before update
      msgs_before = File.read!(ConversationStore.messages_path(id))

      {:ok, updated_meta} =
        ConversationStore.update_meta(id, title: "Better Title", title_source: "auto")

      assert updated_meta["title"] == "Better Title"
      assert updated_meta["title_source"] == "auto"

      # meta.json updated
      meta_json =
        File.read!(ConversationStore.meta_path(id)) |> Jason.decode!()

      assert meta_json["title"] == "Better Title"

      # index.json updated
      index_json =
        File.read!(ConversationStore.index_path()) |> Jason.decode!()

      [idx_entry] = index_json["conversations"]
      assert idx_entry["title"] == "Better Title"

      # messages.jsonl should NOT be touched (content identical)
      msgs_after = File.read!(ConversationStore.messages_path(id))
      assert msgs_after == msgs_before

      # get/1 still returns full conversation with messages
      {:ok, full} = ConversationStore.get(id)
      assert full["title"] == "Better Title"
      assert [%{"content" => "keep me"}] = full["timeline"]
    end

    test "update_meta returns {:error, :not_found} for missing conversation" do
      assert {:error, :not_found} =
               ConversationStore.update_meta("nonexistent-id", title: "Nope")
    end
  end

  describe "rename/2" do
    test "stores a manual title and syncs the index" do
      {:ok, conv} = ConversationStore.create("ws_rename", title: "New chat")

      assert {:ok, meta} = ConversationStore.rename(conv["id"], "  会话重命名  ")
      assert meta["title"] == "会话重命名"
      assert meta["title_source"] == "manual"

      {:ok, stored} = ConversationStore.get_meta(conv["id"])
      assert stored["title"] == "会话重命名"
      assert stored["title_source"] == "manual"

      index = File.read!(ConversationStore.index_path()) |> Jason.decode!()
      entry = Enum.find(index["conversations"], &(&1["id"] == conv["id"]))
      assert entry["title"] == "会话重命名"
    end

    test "rejects blank and oversized titles without writing" do
      {:ok, conv} = ConversationStore.create("ws_rename", title: "Keep me")

      assert {:error, :empty} = ConversationStore.rename(conv["id"], "   \n\t  ")
      assert {:error, :too_long} = ConversationStore.rename(conv["id"], String.duplicate("名", 81))

      {:ok, stored} = ConversationStore.get_meta(conv["id"])
      assert stored["title"] == "Keep me"
      assert stored["title_source"] == "manual"
    end

    test "returns not_found for a missing conversation" do
      assert {:error, :not_found} = ConversationStore.rename("missing-conv", "Title")
    end
  end

  # ── ensure_for_workspaces ───────────────────────────────────────────────

  describe "ensure_for_workspaces/1" do
    test "creates missing workspace conversations" do
      grouped =
        ConversationStore.ensure_for_workspaces([%{"id" => "default"}, %{"id" => "ws_2"}])

      assert [%{"workspace_id" => "default"}] = grouped["default"]
      assert [%{"workspace_id" => "ws_2"}] = grouped["ws_2"]
      assert length(ConversationStore.list()) == 2

      # Verify directory structure exists for each
      for conv <- grouped["default"] ++ grouped["ws_2"] do
        id = conv["id"]
        assert File.dir?(ConversationStore.conversation_dir(id))
        assert File.exists?(ConversationStore.meta_path(id))
        assert File.exists?(ConversationStore.messages_path(id))
        assert File.exists?(ConversationStore.files_path(id))
      end
    end

    test "does not duplicate existing conversations" do
      {:ok, _} = ConversationStore.create("ws_existing")
      assert length(ConversationStore.list_for_workspace("ws_existing")) == 1

      grouped = ConversationStore.ensure_for_workspaces([%{"id" => "ws_existing"}])
      assert length(grouped["ws_existing"]) == 1
      assert length(ConversationStore.list()) == 1
    end
  end

  # ── Edge cases ──────────────────────────────────────────────────────────

  describe "edge cases" do
    test "create respects explicit title_source" do
      {:ok, conv} = ConversationStore.create("ws_1", title: "Auto Named", title_source: "auto")
      assert conv["title_source"] == "auto"
      assert conv["title"] == "Auto Named"
    end

    test "list returns [] when index is missing" do
      assert ConversationStore.list() == []
    end

    test "empty messages.jsonl returns empty timeline" do
      {:ok, conv} = ConversationStore.create("ws_empty_tl", timeline: [])
      {:ok, read} = ConversationStore.get(conv["id"])
      assert read["timeline"] == []
    end
  end
end

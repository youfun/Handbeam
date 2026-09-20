defmodule Handbeam.ThreadsTest do
  use ExUnit.Case, async: false
  alias Handbeam.{ConversationStore, ConversationTranscriptStore, Threads}
  alias Handbeam.Threads.Collaboration

  setup do
    old = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "threads-#{Ecto.UUID.generate()}")
    File.mkdir_p!(home)
    System.put_env("HOME", home)

    on_exit(fn ->
      System.put_env("HOME", old)
      File.rm_rf!(home)
    end)

    {:ok, source} = ConversationStore.create("ws", title: "Source", allow_thread_wakeup: true)
    {:ok, target} = ConversationStore.create("ws", title: "目标")
    {:ok, foreign} = ConversationStore.create("other", title: "Secret")
    context = %{conversation_id: source["id"], workspace_id: "ws", run_id: "source-run"}

    %{
      source: source["id"],
      target: target["id"],
      foreign: foreign["id"],
      context: context,
      home: home
    }
  end

  test "metadata-only discovery, authorization and guessed IDs", c do
    {:ok, _} = ConversationStore.update_meta(c.target, visibility: "internal")
    assert {:ok, %{threads: [%{"id" => id}]}} = Threads.find(%{}, c.context)
    assert id == c.source

    for id <- [c.target, c.foreign, "../index", "", nil] do
      assert {:error, :not_accessible} = Threads.read(%{"thread" => id}, c.context)
      assert {:error, :not_accessible} = Threads.status(%{"thread" => id}, c.context)
    end

    assert {:error, :unauthorized} = Threads.find(%{}, %{})
    assert {:error, :unauthorized} = Threads.find(%{}, %{c.context | workspace_id: "other"})
    assert {:error, :invalid_input} = Threads.find(%{"workspace_id" => "other"}, c.context)
    assert {:error, :unauthorized} = Threads.find(%{}, %{c.context | conversation_id: c.target})
    File.rm!(ConversationStore.messages_path(c.source))
    File.mkdir!(ConversationStore.messages_path(c.source))
    assert {:ok, %{threads: [_]}} = Threads.find(%{}, c.context)
  end

  test "same-time pagination binds query, caller and updates", c do
    for id <- [c.source, c.target], do: ConversationStore.update_meta(id, updated_at: "same")
    input = %{"limit" => 1}
    assert {:ok, %{threads: [a], next_cursor: cursor}} = Threads.find(input, c.context)

    assert {:ok, %{threads: [b], next_cursor: nil}} =
             Threads.find(Map.put(input, "cursor", cursor), c.context)

    assert a["id"] != b["id"]

    assert {:error, :stale_or_invalid_cursor} =
             Threads.find(%{"limit" => 1, "query" => "x", "cursor" => cursor}, c.context)

    ConversationStore.update_meta(c.target, title: "Changed")

    assert {:error, :stale_or_invalid_cursor} =
             Threads.find(Map.put(input, "cursor", cursor), c.context)
  end

  test "Unicode and single-message continuation preserve the entire tail", c do
    body = "甲🙂é乙終"

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{
        "id" => "stable",
        "role" => "assistant",
        "content" => body,
        "details" => %{secret: "hidden"}
      })

    input = %{"thread" => c.target, "max_chars" => 2}
    {:ok, p1} = Threads.read(input, c.context)
    {:ok, p2} = Threads.read(Map.put(input, "cursor", p1.next_cursor), c.context)
    {:ok, p3} = Threads.read(Map.put(input, "cursor", p2.next_cursor), c.context)
    assert Enum.map_join(p1.messages ++ p2.messages ++ p3.messages, & &1["content"]) == body
    assert Enum.map(p1.messages ++ p2.messages ++ p3.messages, & &1["offset"]) == [0, 2, 4]
    assert Enum.all?(p1.messages ++ p2.messages ++ p3.messages, &(&1["id"] == "stable"))
    refute Map.has_key?(hd(p1.messages), "details")
    assert p3.next_cursor == nil

    {:ok, _} =
      ConversationTranscriptStore.append(c.target, %{"id" => "new", "content" => "append"})

    assert {:error, :stale_or_invalid_cursor} =
             Threads.read(Map.put(input, "cursor", p1.next_cursor), c.context)

    {:ok, fresh} = Threads.read(input, c.context)
    ConversationTranscriptStore.update(c.target, "stable", %{"content" => "edited"})

    assert {:error, :stale_or_invalid_cursor} =
             Threads.read(Map.put(input, "cursor", fresh.next_cursor), c.context)
  end

  test "historical status is idle without inventing success", c do
    assert {:ok, %{state: "idle", current_run: nil, last_result: nil}} =
             Threads.status(%{"thread" => c.target}, c.context)
  end

  test "stale workspace index cannot expose moved metadata", c do
    {:ok, meta} = ConversationStore.get_metadata(c.target)

    File.write!(
      ConversationStore.meta_path(c.target),
      Jason.encode!(Map.put(meta, "workspace_id", "other"))
    )

    assert {:ok, %{threads: [%{"id" => id}]}} = Threads.find(%{}, c.context)
    assert id == c.source
  end

  test "date filtering normalizes offsets and rejects malformed input", c do
    {:ok, %{threads: []}} =
      Threads.find(%{"updated_after" => "2999-01-01T00:00:00+08:00"}, c.context)

    {:ok, %{threads: threads}} =
      Threads.find(%{"updated_after" => "2000-01-01T00:00:00+08:00"}, c.context)

    assert length(threads) == 2
    assert {:error, :invalid_input} = Threads.find(%{"updated_after" => "nonsense"}, c.context)
  end

  test "fragment count bounds empty messages and deletion invalidates continuation", c do
    for i <- 1..51,
        do: ConversationTranscriptStore.append(c.target, %{"id" => "m#{i}", "content" => ""})

    {:ok, page} = Threads.read(%{"thread" => c.target}, c.context)
    assert length(page.messages) == 50
    {:ok, tail} = Threads.read(%{"thread" => c.target, "cursor" => page.next_cursor}, c.context)
    assert [%{"id" => "m51"}] = tail.messages
    assert tail.next_cursor == nil
    ConversationTranscriptStore.delete(c.target, "m1")

    assert {:error, :stale_or_invalid_cursor} =
             Threads.read(%{"thread" => c.target, "cursor" => page.next_cursor}, c.context)
  end

  test "permission revocation and cross-workspace send reject before persistence", c do
    ConversationStore.update_meta(c.foreign, allow_thread_wakeup: true)
    input = %{"thread" => c.foreign, "message" => "x", "request_id" => "x"}
    assert {:error, :not_accessible} = Collaboration.send_message(input, c.context)
    ConversationStore.update_meta(c.target, allow_thread_wakeup: true)
    ConversationStore.update_meta(c.source, allow_thread_wakeup: false)

    assert {:error, :handoff_not_permitted} =
             Collaboration.send_message(%{input | "thread" => c.target}, c.context)

    assert {:ok, []} = ConversationTranscriptStore.list(c.source)
  end

  test "concurrent identical sends reserve only once; uncertain delivery is not retried", c do
    ConversationStore.update_meta(c.target, allow_thread_wakeup: true)
    input = %{"thread" => c.target, "message" => "Report", "request_id" => "request"}

    results =
      1..8
      |> Task.async_stream(fn _ -> Collaboration.send_message(input, c.context) end)
      |> Enum.to_list()

    assert Enum.all?(results, fn {:ok, {:ok, receipt}} ->
             receipt.delivery == "delivery_unknown"
           end)

    {:ok, entries} = ConversationTranscriptStore.list(c.source)
    assert length(entries) == 1
    assert hd(entries)["content"] == "Report"

    assert {:error, :idempotency_conflict} =
             Collaboration.send_message(%{input | "message" => "Changed"}, c.context)

    assert {:ok, []} = ConversationTranscriptStore.list(c.target)
  end

  test "explicit opt-in, child cap, trusted parent and immutable read-only metadata", c do
    input = %{"title" => "Audit", "message" => "Inspect", "request_id" => "child"}
    ConversationStore.update_meta(c.source, allow_thread_wakeup: false)
    assert {:error, :delegation_not_permitted} = Collaboration.create(input, c.context)
    ConversationStore.update_meta(c.source, allow_thread_wakeup: true)
    {:ok, receipt} = Collaboration.create(input, c.context)
    {:ok, same} = Collaboration.create(input, c.context)
    assert same.thread == receipt.thread
    child_context = %{c.context | conversation_id: receipt.thread}
    refute Collaboration.tool_allowed?("bash", child_context)
    refute Collaboration.tool_allowed?("write", child_context)
    assert Collaboration.tool_allowed?("read", child_context)

    ConversationStore.upsert(%{
      "id" => receipt.thread,
      "workspace_id" => "ws",
      "title" => "UI save",
      "timeline" => []
    })

    refute Collaboration.tool_allowed?("write", child_context)

    assert {:error, :invalid_input} =
             Collaboration.reply(
               %{"thread" => c.foreign, "message" => "x", "request_id" => "reply"},
               child_context
             )

    assert {:ok, %{thread: parent}} =
             Collaboration.reply(%{"message" => "Result", "request_id" => "reply"}, child_context)

    assert parent == c.source
    assert {:error, :delegation_not_permitted} = Collaboration.create(input, child_context)

    for i <- 2..3,
        do:
          assert(
            {:ok, _} = Collaboration.create(%{input | "request_id" => "child#{i}"}, c.context)
          )

    assert {:error, :child_limit} =
             Collaboration.create(%{input | "request_id" => "child4"}, c.context)
  end

  test "finite handoff budget prevents unbounded mutual wakeups", c do
    ConversationStore.update_meta(c.target, allow_thread_wakeup: true)

    for i <- 1..8 do
      assert {:ok, _} =
               Collaboration.send_message(
                 %{"thread" => c.target, "message" => "x", "request_id" => "#{i}"},
                 c.context
               )
    end

    assert {:error, :handoff_budget_exhausted} =
             Collaboration.send_message(
               %{"thread" => c.target, "message" => "x", "request_id" => "9"},
               c.context
             )
  end

  test "registered tools use executor-owned context and deny writes in delegated runs", c do
    modules = Handbeam.Tool.Registry.host_tool_modules()
    names = Enum.map(modules, & &1.name())

    for name <-
          ~w(find_thread read_thread get_thread_status send_thread_message reply_to_parent_thread create_thread),
        do: assert(name in names)

    Enum.each(modules, &Handbeam.Tool.Registry.register/1)

    config =
      Handbeam.Agent.Config.from_opts(
        conversation_id: c.source,
        workspace_id: "ws",
        working_directory: c.home,
        context: %{thread_run_opts: [forged: true]}
      )

    state = Handbeam.Agent.State.init(config, "test")

    assert {:ok, _, [block]} =
             Handbeam.Agent.Tool.Executor.execute_all_with_details(
               [%{id: "find", name: "find_thread", input: %{}}],
               state
             )

    refute block.is_error
    assert Jason.decode!(block.content)["threads"] |> length() == 2
    ConversationStore.update_meta(c.source, collaboration: %{"read_only" => true})
    path = Path.join(c.home, "must-not-exist")

    assert {:ok, _, [denied]} =
             Handbeam.Agent.Tool.Executor.execute_all_with_details(
               [%{id: "write", name: "write", input: %{"file_path" => path, "content" => "bad"}}],
               state
             )

    assert denied.is_error
    refute File.exists?(path)
  end
end

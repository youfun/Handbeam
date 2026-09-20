defmodule Handbeam.ConversationTranscriptStoreTest do
  use ExUnit.Case, async: false

  alias Handbeam.ConversationTranscriptStore
  alias Handbeam.ConversationTranscriptStore.Journal

  setup do
    old_home = System.get_env("HOME")

    home_dir =
      Path.join(
        System.tmp_dir!(),
        "sigil_conversation_transcript_home_#{System.unique_integer([:positive])}"
      )

    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      if File.exists?(home_dir), do: File.rm_rf!(home_dir)
    end)

    :ok
  end

  test "append, list, and update transcript entries" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", id: "transcript-store")
    conversation_id = conversation["id"]

    assert {:ok, user} =
             ConversationTranscriptStore.append(conversation_id, %{
               "id" => "msg-user-1",
               "role" => "user",
               "content" => "hello",
               "direction" => "inbound",
               "channel" => "sns"
             })

    assert user["sequence"] == 1

    assert {:ok, assistant} =
             ConversationTranscriptStore.append(conversation_id, %{
               "id" => "msg-assistant-1",
               "role" => "assistant",
               "content" => "hi",
               "direction" => "outbound",
               "channel" => "sns"
             })

    assert assistant["sequence"] == 2

    assert {:ok, updated} =
             ConversationTranscriptStore.update(conversation_id, "msg-assistant-1", %{
               "content" => %{"$append" => " there"},
               "status" => "streaming"
             })

    assert updated["content"] == "hi there"

    assert {:ok, entries} = ConversationTranscriptStore.list(conversation_id)
    assert Enum.map(entries, & &1["id"]) == ["msg-user-1", "msg-assistant-1"]
  end

  test "delete removes only its target and is idempotent" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", id: "transcript-delete")
    id = conversation["id"]
    {:ok, first} = ConversationTranscriptStore.append(id, %{"id" => "first", "content" => "one"})
    {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "remove", "content" => "two"})
    {:ok, last} = ConversationTranscriptStore.append(id, %{"id" => "last", "content" => "three"})

    assert :ok = ConversationTranscriptStore.delete(id, "remove")
    assert {:ok, [^first, ^last]} = ConversationTranscriptStore.list(id)
    assert :ok = ConversationTranscriptStore.delete(id, "remove")
    assert {:ok, [^first, ^last]} = ConversationTranscriptStore.list(id)
  end

  test "serializes concurrent appends, updates, and deletes without losing entries" do
    {:ok, conversation} =
      Handbeam.ConversationStore.create("default", id: "transcript-concurrent")

    conversation_id = conversation["id"]

    assert {:ok, _entry} =
             ConversationTranscriptStore.append(conversation_id, %{
               "id" => "streamed",
               "role" => "assistant",
               "content" => ""
             })

    parent = self()

    for index <- 1..10 do
      assert {:ok, _} =
               ConversationTranscriptStore.append(conversation_id, %{"id" => "remove-#{index}"})
    end

    tasks =
      for index <- 1..50 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              cond do
                index > 40 ->
                  ConversationTranscriptStore.delete(conversation_id, "remove-#{index - 40}")

                rem(index, 2) == 0 ->
                  ConversationTranscriptStore.append(conversation_id, %{
                    "id" => "appended-#{index}",
                    "role" => "user",
                    "content" => Integer.to_string(index)
                  })

                true ->
                  ConversationTranscriptStore.update(conversation_id, "streamed", %{
                    "content" => %{"$append" => "x"}
                  })
              end
          end
        end)
      end

    Enum.each(tasks, fn task ->
      assert_receive {:ready, task_pid} when task_pid == task.pid
    end)

    Enum.each(tasks, &send(&1.pid, :go))

    Enum.each(tasks, fn task ->
      result = Task.await(task, 5_000)
      assert result == :ok or match?({:ok, _}, result)
    end)

    assert {:ok, entries} = ConversationTranscriptStore.list(conversation_id)
    assert length(entries) == 21
    assert Enum.find(entries, &(&1["id"] == "streamed"))["content"] == String.duplicate("x", 20)

    assert Enum.sort(Enum.map(entries, & &1["id"])) ==
             Enum.sort(["streamed" | Enum.map(2..40//2, &"appended-#{&1}")])
  end

  test "replays legacy entries and journal revisions after owner restart" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", id: "transcript-replay")
    id = conversation["id"]
    path = Handbeam.ConversationStore.messages_path(id)

    File.write!(
      path,
      Jason.encode!(%{"id" => "legacy", "content" => "a", "sequence" => 7}) <> "\n"
    )

    assert {:ok, _} =
             ConversationTranscriptStore.update(id, "legacy", %{"content" => %{"$append" => "b"}})

    assert {:ok, appended} =
             ConversationTranscriptStore.append(id, %{"id" => "new", "content" => "c"})

    assert appended["sequence"] == 8

    restart_journal()

    assert {:ok, entries} = ConversationTranscriptStore.list(id)
    assert Enum.map(entries, &{&1["id"], &1["content"]}) == [{"legacy", "ab"}, {"new", "c"}]
  end

  test "ignores only a partial trailing crash record and reports non-tail corruption" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", id: "transcript-partial")
    id = conversation["id"]
    path = Handbeam.ConversationStore.messages_path(id)
    File.write!(path, Jason.encode!(%{"id" => "ok"}) <> "\n{\"partial\":")

    assert {:ok, [%{"id" => "ok"}]} = ConversationTranscriptStore.list(id)

    assert {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "after"})
    restart_journal()

    assert {:ok, entries} = ConversationTranscriptStore.list(id)
    assert Enum.map(entries, & &1["id"]) == ["ok", "after"]

    File.write!(path, "broken\n" <> Jason.encode!(%{"id" => "hidden"}) <> "\n")
    Journal.invalidate(path)
    assert {:error, {:corrupt_journal, 1}} = ConversationTranscriptStore.list(id)
  end

  test "preserves a valid final unterminated record when appending" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", id: "unterminated")
    id = conversation["id"]
    path = Handbeam.ConversationStore.messages_path(id)
    File.write!(path, Jason.encode!(%{"id" => "first", "sequence" => 4}))

    assert {:ok, %{"sequence" => 5}} =
             ConversationTranscriptStore.append(id, %{"id" => "second"})

    restart_journal()
    assert {:ok, entries} = ConversationTranscriptStore.list(id)
    assert Enum.map(entries, & &1["id"]) == ["first", "second"]
  end

  test "rejects unknown journal record versions" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", id: "unknown-version")
    id = conversation["id"]
    path = Handbeam.ConversationStore.messages_path(id)

    File.write!(
      path,
      Jason.encode!(%{"$handbeam_journal" => 99, "op" => "delete", "id" => "x"}) <> "\n"
    )

    Journal.invalidate(path)

    assert {:error, {:corrupt_journal, 1, {:unsupported_version, 99}}} =
             ConversationTranscriptStore.list(id)
  end

  test "invalid update payload fails the read without killing the journal owner" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default")
    id = conversation["id"]
    {:ok, _} = ConversationTranscriptStore.append(id, %{"id" => "existing"})
    path = Handbeam.ConversationStore.messages_path(id)
    owner = Process.whereis(Journal)
    File.write!(path, Jason.encode!(%{"id" => "existing"}) <> "\n")

    File.write!(
      path,
      Jason.encode!(%{
        "$handbeam_journal" => 1,
        "op" => "update",
        "id" => "existing",
        "patch" => "invalid"
      }) <> "\n",
      [:append]
    )

    assert {:error, {:corrupt_journal, 2, _reason}} = ConversationTranscriptStore.list(id)
    assert Process.whereis(Journal) == owner
  end

  test "cache notices atomic same-size replacement" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", id: "same-size-replace")
    id = conversation["id"]
    path = Handbeam.ConversationStore.messages_path(id)
    first = Jason.encode!(%{"id" => "one"}) <> "\n"
    second = Jason.encode!(%{"id" => "two"}) <> "\n"
    assert byte_size(first) == byte_size(second)
    File.write!(path, first)
    Journal.invalidate(path)
    assert {:ok, [%{"id" => "one"}]} = ConversationTranscriptStore.list(id)

    replacement = path <> ".replacement"
    File.write!(replacement, second)
    File.rename!(replacement, path)

    assert {:ok, [%{"id" => "two"}]} = ConversationTranscriptStore.list(id)
  end

  test "returns storage read failures instead of treating them as empty" do
    {:ok, conversation} =
      Handbeam.ConversationStore.create("default", id: "transcript-read-error")

    path = Handbeam.ConversationStore.messages_path(conversation["id"])
    File.rm!(path)
    File.mkdir!(path)

    assert {:error, :eisdir} = ConversationTranscriptStore.list(conversation["id"])
  end

  defp restart_journal do
    :ok = Supervisor.terminate_child(Handbeam.Supervisor, Journal)
    {:ok, _pid} = Supervisor.restart_child(Handbeam.Supervisor, Journal)
  end
end

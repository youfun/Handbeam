defmodule Handbeam.E2E.TranscriptDurabilityTest do
  @moduledoc """
  A user-reachable durability path per test:

  1. A second VM/OS process holding `.handbeam-storage.lock` blocks every
     conversation write (nothing is created or corrupted); once it releases,
     the same conversation runs to completion, and the first VM's ownership
     is visible to the outside process.
  2. A host crash leaves orphaned streaming replies / running tools / a
     synced pending intent; startup recovery drains the intent exactly once
     and seals the orphans without touching completed runs.
  3. A long streaming reply compacts the journal file instead of growing it
     without bound, preserving the full timeline, page cursors, and the
     sequence high-water mark.
  4. Parallel writers to one conversation serialize through the journal.

  Run: mix test --include e2e test/handbeam/e2e/transcript_durability_test.exs
  """

  use ExUnit.Case, async: false

  alias Handbeam.Agent.Coordinator
  alias Handbeam.ConversationStore
  alias Handbeam.ConversationTranscriptStore
  alias Handbeam.PubSub.Session

  @moduletag :e2e

  @error_text "Run error: Host stopped before the run completed"

  # Cross-process lock probe: takes a non-blocking flock, prints LOCKED, and
  # holds it until <release_path> exists. Exit code 3 = lock already held (BUSY).
  @lock_holder_script ~s"""
  import fcntl
  import os
  import sys
  import time


  def main():
      lock_path, release_path = sys.argv[1], sys.argv[2]
      os.makedirs(os.path.dirname(lock_path), exist_ok=True)
      handle = open(lock_path, "a+")

      try:
          fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
      except OSError:
          print("BUSY", flush=True)
          return 3

      print("LOCKED", flush=True)

      while not os.path.exists(release_path):
          time.sleep(0.02)

      print("RELEASED", flush=True)
      return 0


  if __name__ == "__main__":
      sys.exit(main())
  """

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbeam.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbeam.Repo, {:shared, self()})

    root = Path.join(System.tmp_dir!(), "transcript-e2e-#{Ecto.UUID.generate()}")
    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(home)
    File.mkdir_p!(workspace)

    lock_holder = Path.join(root, "lock_holder.py")
    File.write!(lock_holder, @lock_holder_script)

    old_home = System.get_env("HOME")
    old_models = System.get_env("HANDBEAM_MODELS_FILE")
    models = Path.join(root, "models.json")

    File.write!(
      models,
      ~s({"providers": {"fake": {"baseUrl": "http://localhost", "api": "openai-chat-completions", "apiKey": "sk-fake", "models": [{"id": "fake-model", "name": "Fake Model"}]}}})
    )

    System.put_env("HOME", home)
    System.put_env("HANDBEAM_MODELS_FILE", models)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")

      if old_models,
        do: System.put_env("HANDBEAM_MODELS_FILE", old_models),
        else: System.delete_env("HANDBEAM_MODELS_FILE")

      File.rm_rf!(root)
    end)

    %{
      root: root,
      home: home,
      workspace: workspace,
      lock_holder: lock_holder,
      store_root: Path.join([home, ".handbeam", "conversations"])
    }
  end

  # ── 1. Cross-VM storage lock ──────────────────────────────────────────────

  test "a second VM holding the storage lock blocks writes without corruption, and the VM's ownership is visible cross-process",
       %{
         store_root: store_root,
         workspace: workspace,
         lock_holder: lock_holder
       } do
    lock_path = Path.join(store_root, ".handbeam-storage.lock")
    release = Path.join(store_root, "release")
    start_lock_holder(lock_holder, lock_path, release)
    assert_receive {:lock_holder, "LOCKED"}, 5_000

    # No conversation state may be created or rewritten while it is locked.
    sid = "lock-e2e-#{System.unique_integer([:positive])}"
    assert {:error, :locked} = ConversationStore.create("default", id: sid)

    # The run is refused before anything is written; the exact failure point
    # (meta read vs inbound persist) is an implementation detail.
    assert {:error, :locked} =
             Coordinator.add_message(sid, "hello",
               workspace_path: workspace,
               model: "fake/fake-model",
               provider: Handbeam.TestSupport.FakeProvider,
               provider_config: %{scenario: :simple_answer},
               tools: [],
               source: :cli,
               streaming: false,
               max_turns: 3
             )

    refute File.exists?(Path.join([store_root, "items", sid])),
           "no conversation directory may appear while the lock is held elsewhere"

    # Release: the same conversation now runs to completion.
    File.write!(release, "go")
    assert_receive {:lock_holder, "RELEASED"}, 5_000
    assert_receive {:lock_holder_exit, 0}, 5_000

    {:ok, _} = ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "hello",
               workspace_path: workspace,
               model: "fake/fake-model",
               provider: Handbeam.TestSupport.FakeProvider,
               provider_config: %{scenario: :simple_answer},
               tools: [],
               source: :cli,
               streaming: false,
               max_turns: 3
             )

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 15_000
    settle(sid)

    {:ok, entries} = ConversationTranscriptStore.list(sid)
    roles = Enum.map(entries, & &1["role"])
    assert roles == ["user", "assistant"]
    assert hd(entries)["content"] == "hello"
    assert Enum.any?(entries, &(&1["role"] == "assistant" and &1["status"] == "completed"))

    # Reverse direction: this VM's journal now owns the lock for the storage
    # root, and an outside process is refused (exit code 3 = BUSY).
    {output, 3} =
      System.cmd(python3!(), [lock_holder, lock_path, release], stderr_to_stdout: true)

    assert output =~ "BUSY"
  end

  # ── 2. Crash recovery: orphan sealing + pending intent drain ──────────────

  test "recovery seals orphaned streaming replies and drains a crash-era pending intent exactly once",
       %{
         workspace: workspace
       } do
    # Baseline: a completed run that recovery must not touch.
    done_id = "recovery-done-#{System.unique_integer([:positive])}"
    {:ok, _} = ConversationStore.create("default", id: done_id)
    :ok = Session.subscribe(done_id)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(done_id, "baseline",
               workspace_path: workspace,
               model: "fake/fake-model",
               provider: Handbeam.TestSupport.FakeProvider,
               provider_config: %{scenario: :simple_answer},
               tools: [],
               source: :cli,
               streaming: false,
               max_turns: 3
             )

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 15_000
    settle(done_id)

    # Orphan: a host restart never delivered run_end for run-orphan. The
    # transcript on disk is the legacy plain-JSONL release plus a synced
    # pending intent holding the last visible delta.
    orphan_id = "recovery-orphan-#{System.unique_integer([:positive])}"
    {:ok, _} = ConversationStore.create("default", id: orphan_id)

    orphan_entry = %{
      "id" => "msg-assistant-orphan",
      "content_type" => "assistant_msg",
      "role" => "assistant",
      "status" => "streaming",
      "run_id" => "run-orphan",
      "content" => "partial"
    }

    messages_path =
      Path.join([ConversationStore.storage_dir(), "items", orphan_id, "messages.jsonl"])

    File.write!(messages_path, Jason.encode!(orphan_entry) <> "\n")

    intent = %{
      "$handbeam_journal" => 1,
      "op" => "update",
      "id" => "msg-assistant-orphan",
      "txid" => 1,
      "patch" => %{"content" => %{"$append" => " tail"}}
    }

    File.write!(messages_path <> ".pending", Jason.encode!(intent) <> "\n", [:sync])

    assert :ok = Handbeam.Agent.TranscriptRecovery.recover(orphan_id)
    assert :ok = Handbeam.Agent.TranscriptRecovery.recover(done_id)

    refute File.exists?(messages_path <> ".pending"), "the intent must be drained, not left"

    {:ok, orphan_entries} = ConversationTranscriptStore.list(orphan_id)
    ids = Enum.map(orphan_entries, & &1["id"])
    assert "msg-assistant-orphan" in ids
    assert Enum.count(ids, &(&1 == "msg-run-error-run-orphan")) == 1

    sealed = Enum.find(orphan_entries, &(&1["id"] == "msg-assistant-orphan"))
    assert sealed["content"] == "partial tail", "the intent delta is applied exactly once"
    assert sealed["status"] == "error"

    error_entry = Enum.find(orphan_entries, &(&1["id"] == "msg-run-error-run-orphan"))
    assert error_entry["content"] == @error_text
    assert error_entry["role"] == "system"

    # The completed baseline run keeps its final state.
    {:ok, done_entries} = ConversationTranscriptStore.list(done_id)

    assert Enum.any?(
             done_entries,
             &(&1["role"] == "assistant" and &1["status"] == "completed" and
                 &1["content"] == "Hello! I am a fake provider response.")
           )

    refute Enum.any?(done_entries, &(&1["content"] == @error_text))
  end

  # ── 3. Compaction of a long streaming reply ───────────────────────────────

  test "a long streaming reply compacts the journal and keeps the full timeline, cursors, and sequence",
       %{
         workspace: _workspace
       } do
    sid = "compact-e2e-#{System.unique_integer([:positive])}"
    {:ok, _} = ConversationStore.create("default", id: sid)

    {:ok, base} =
      ConversationTranscriptStore.append(sid, %{
        "id" => "msg-assistant-compact",
        "content_type" => "assistant_msg",
        "role" => "assistant",
        "status" => "streaming",
        "content" => "0"
      })

    assert base["id"] == "msg-assistant-compact"

    # The same mutation shape TranscriptPersistence.flush!/2 uses for deltas.
    for _ <- 1..300 do
      assert {:ok, _} =
               ConversationTranscriptStore.update(sid, "msg-assistant-compact", %{
                 "content" => %{"$append" => "x"}
               })
    end

    # The physical file is compacted at the 256-revision threshold: what
    # remains is the checkpoint plus the post-compaction revisions, not the
    # full 300-revision history (which would be ~301 lines).
    messages_path = Path.join([ConversationStore.storage_dir(), "items", sid, "messages.jsonl"])
    lines = String.split(File.read!(messages_path), "\n", trim: true)
    assert length(lines) <= 60, "expected a compacted journal, got #{length(lines)} lines"

    # Cold read replays to the same complete timeline.
    {:ok, [entry]} = ConversationTranscriptStore.list(sid)
    assert entry["content"] == "0" <> String.duplicate("x", 300)
    assert entry["status"] == "streaming"

    # Paging still works over the compacted file.
    assert {:ok, %{entries: [paged], has_more?: false}} =
             ConversationTranscriptStore.page(sid, limit: 1)

    assert paged["id"] == "msg-assistant-compact"

    # The sequence high-water mark survives compaction.
    assert {:ok, _} = ConversationTranscriptStore.append(sid, %{"id" => "msg-after-compact"})
  end

  # ── 4. Parallel writers serialize through the journal ─────────────────────

  test "parallel writers to one conversation produce a complete, valid timeline", %{
    workspace: _workspace
  } do
    sid = "parallel-e2e-#{System.unique_integer([:positive])}"
    {:ok, _} = ConversationStore.create("default", id: sid)

    writers =
      for w <- 1..6 do
        Task.async(fn ->
          for n <- 1..10 do
            {:ok, _} =
              ConversationTranscriptStore.append(sid, %{
                "id" => "msg-#{w}-#{n}",
                "content_type" => "assistant_msg",
                "role" => "assistant",
                "status" => "completed",
                "content" => "writer #{w} entry #{n}"
              })
          end

          w
        end)
      end

    assert [1, 2, 3, 4, 5, 6] == Enum.sort(Task.await_many(writers, 30_000))

    {:ok, entries} = ConversationTranscriptStore.list(sid)
    assert length(entries) == 60
    ids = Enum.map(entries, & &1["id"])
    assert ids == Enum.uniq(ids), "no entry may be written twice"
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp settle(sid, attempts \\ 200) do
    busy? = Registry.lookup(Handbeam.AgentRunRegistry, sid) != []

    cond do
      busy? and attempts > 0 ->
        receive do
        after
          20 -> settle(sid, attempts - 1)
        end

      busy? ->
        flunk("run did not settle")

      true ->
        for pid <- Task.Supervisor.children(Handbeam.AgentRunTaskSupervisor) do
          ref = Process.monitor(pid)
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
        end

        {:ok, session} = Session.start_or_get(session_id: sid)
        :sys.get_state(session)

        if tracker = Process.whereis(Handbeam.Runtime.TaskTracker), do: :sys.get_state(tracker)

        :ok
    end
  end

  defp python3! do
    System.find_executable("python3") ||
      raise "python3 is required for the transcript durability e2e"
  end

  # Runs the lock-holder script on a port owned by a forwarder process so the
  # test mailbox receives {:lock_holder, line} and {:lock_holder_exit, code}.
  defp start_lock_holder(script, lock_path, release) do
    test_pid = self()

    spawn_link(fn ->
      port =
        Port.open({:spawn_executable, python3!()}, [
          :binary,
          :exit_status,
          args: [script, lock_path, release]
        ])

      forward_loop(port, test_pid)
    end)

    :ok
  end

  defp forward_loop(port, test_pid) do
    receive do
      {^port, {:data, data}} ->
        send(test_pid, {:lock_holder, String.trim(data)})
        forward_loop(port, test_pid)

      {^port, {:exit_status, code}} ->
        send(test_pid, {:lock_holder_exit, code})
    after
      60_000 -> :ok
    end
  end
end

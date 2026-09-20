defmodule Handbeam.Agent.TranscriptRecoveryTest do
  use ExUnit.Case, async: false

  alias Handbeam.Agent.{TranscriptPersistence, TranscriptRecovery}
  alias Handbeam.ConversationTranscriptStore
  alias Handbeam.ConversationTranscriptStore.Journal

  setup do
    old_home = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "handbeam-recovery-#{Ecto.UUID.generate()}")
    System.put_env("HOME", home)
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      File.rm_rf!(home)
    end)

    %{id: conversation["id"]}
  end

  test "replays acknowledged text after writer death and journal restart, then recovers once", %{
    id: id
  } do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        opts = [run_id: "orphan"]
        :ok = TranscriptPersistence.handle_event(id, {:run_start, %{}}, opts)

        :ok =
          TranscriptPersistence.handle_event(
            id,
            {:tool_start, %{tool: "read", tool_use_id: "pending"}},
            opts
          )

        :ok = TranscriptPersistence.handle_event(id, {:message_delta, %{chunk: "已完成 "}}, opts)
        :ok = TranscriptPersistence.handle_event(id, {:message_delta, %{chunk: "part two"}}, opts)
        send(parent, :durable)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :durable
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    :ok = Supervisor.terminate_child(Handbeam.Supervisor, Journal)
    {:ok, _} = Supervisor.restart_child(Handbeam.Supervisor, Journal)
    assert {:ok, [tool, assistant]} = ConversationTranscriptStore.list(id)
    assert assistant["content"] == "已完成 part two"
    assert assistant["status"] == "streaming"
    assert tool["tool_status"] == "running"

    assert :ok = TranscriptRecovery.run()
    assert :ok = TranscriptRecovery.run()
    assert {:ok, [tool, assistant, error]} = ConversationTranscriptStore.list(id)
    assert assistant["content"] == "已完成 part two"
    assert assistant["status"] == "error"
    assert tool["tool_status"] == "error"
    assert error["id"] == "msg-run-error-orphan"
    assert error["content"] =~ "Host stopped"
  end

  test "cross-process error closure leaves other runs and completed tools untouched", %{id: id} do
    for {entry_id, run_id, status} <- [
          {"old", "old-run", "running"},
          {"done", "broken", "done"},
          {"pending", "broken", "running"}
        ] do
      {:ok, _} =
        ConversationTranscriptStore.append(id, %{
          "id" => entry_id,
          "run_id" => run_id,
          "role" => "tool",
          "content_type" => "tool",
          "tool_status" => status
        })
    end

    task =
      Task.async(fn ->
        TranscriptPersistence.handle_event(
          id,
          {:run_end, %{status: "error", error: "provider died"}},
          run_id: "broken"
        )
      end)

    assert :ok = Task.await(task)
    assert {:ok, [old, done, failed, error]} = ConversationTranscriptStore.list(id)
    assert old["tool_status"] == "running"
    assert done["tool_status"] == "done"
    assert failed["tool_status"] == "error"
    assert failed["tool_error"] == "provider died"
    assert error["run_id"] == "broken"
  end
end

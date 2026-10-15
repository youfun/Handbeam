defmodule Handbeam.PubSub.SessionSQLiteTest do
  use Handbeam.DataCase, async: false

  alias Handbeam.PubSub.{AgentEvent, Session}

  setup do
    id = "stored-session-#{System.unique_integer([:positive])}"
    {:ok, _conversation} = Handbeam.ConversationStore.create("default", id: id)

    on_exit(fn ->
      sync_task_tracker()
      if Session.whereis(id), do: Handbeam.SessionSupervisor.stop_session(id)
      sync_task_tracker()
    end)

    %{id: id}
  end

  test "turn bursts are throttled until run_end persists the terminal snapshot", %{id: id} do
    {:ok, pid} =
      Session.start_or_get(session_id: id, model: "fake", session_store_enabled?: true)

    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: id, owner: self())
    :ok = Session.attach_run(id, self(), queue, run_id: "run-1")
    Session.broadcast_event(id, :run_start, %{run_id: "run-1", model: "fake"})
    assert %{last_seq: 1} = Session.snapshot(id)

    :sys.replace_state(pid, &%{&1 | last_throttle: System.monotonic_time(:millisecond)})

    for turn <- 1..20 do
      Session.broadcast_event(id, :turn_end, %{
        run_id: "run-1",
        turn: turn,
        status: :completed
      })
    end

    assert %{last_seq: 21} = Session.snapshot(id)
    assert {:ok, %{"seq" => 1}} = Handbeam.SessionStore.SQLite.load(id)

    Session.append_event(
      id,
      AgentEvent.new(
        Session.session_topic(id),
        :run_end,
        %{run_id: "run-1", status: :completed, turns: 20},
        22
      )
    )

    assert %{last_seq: 22} = Session.snapshot(id)

    assert {:ok, %{"seq" => 22, "events" => [%{"kind" => "run_end"} | _]}} =
             Handbeam.SessionStore.SQLite.load(id)

    assert :ok = Session.mark_run_finished(id, "run-1")
  end

  test "restart restores persisted events and next-turn messages without runtime handles", %{
    id: id
  } do
    {:ok, pid1} =
      Session.start_or_get(session_id: id, model: "fake", session_store_enabled?: true)

    Session.broadcast_event(id, :run_start, %{model: "fake"})
    :ok = Session.enqueue_candidate(id, "remember me", deliver_as: :next_turn)
    assert %{last_seq: 2} = Session.snapshot(id)
    sync_task_tracker()
    :ok = Handbeam.SessionSupervisor.stop_session(id)
    refute Process.alive?(pid1)

    {:ok, pid2} =
      Session.start_or_get(session_id: id, model: "fake", session_store_enabled?: true)

    assert pid2 != pid1

    %{
      last_seq: 2,
      events: [
        %AgentEvent{kind: :candidate_message_injected},
        %AgentEvent{kind: :run_start}
      ],
      meta: meta
    } = Session.snapshot(id)

    assert meta.running? == false
    assert meta.agent_pid == nil
    assert meta.queue_pid == nil

    assert [%Handbeam.Agent.Message{role: :user, content: "remember me"}] =
             Session.drain_next_turn(id)
  end

  defp sync_task_tracker do
    case Process.whereis(Handbeam.Runtime.TaskTracker) do
      nil -> :ok
      pid -> :sys.get_state(pid)
    end
  end
end

defmodule Handbeam.Runtime.TaskTrackerTest do
  use ExUnit.Case, async: false

  alias Handbeam.PubSub.Session
  alias Handbeam.Runtime.NotifyAdapter
  alias Handbeam.Runtime.TaskTracker

  defmodule CaptureAdapter do
    @behaviour NotifyAdapter

    @impl true
    def app_visible?, do: Application.get_env(:handbeam, :runtime_notify_visible, false)

    @impl true
    def apply(action) do
      case Process.whereis(:runtime_notify_capture) do
        pid when is_pid(pid) -> send(pid, {:notify_action, action})
        _ -> :ok
      end
    end
  end

  setup do
    Process.register(self(), :runtime_notify_capture)
    previous = Application.get_env(:handbeam, :runtime_notify_adapter)
    Application.put_env(:handbeam, :runtime_notify_adapter, CaptureAdapter)
    Application.put_env(:handbeam, :runtime_notify_visible, false)
    TaskTracker.reset()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbeam, :runtime_notify_adapter, previous),
        else: Application.delete_env(:handbeam, :runtime_notify_adapter)

      Application.delete_env(:handbeam, :runtime_notify_visible)
      TaskTracker.reset()
    end)

    :ok
  end

  test "follow-up stays one task until the runner actually finishes" do
    sid = "task-follow-#{System.unique_integer([:positive])}"
    {:ok, _} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue, run_id: "run-1")

    Session.broadcast_event(sid, :run_start, %{model: "fake"})

    assert_receive {:notify_action, {:update_running, %{running_count: 1, waiting_count: 0}}},
                   500

    Session.broadcast_event(sid, :run_end, %{status: "interrupted", turns: 1})

    assert_receive {:notify_action, {:update_running, %{running_count: 0, waiting_count: 1}}},
                   500

    refute_received {:notify_action, {:system_ended, _, _}}

    Session.broadcast_event(sid, :run_end, %{status: "completed", turns: 2})
    assert_receive {:notify_action, {:update_running, %{running_count: 0, waiting_count: 0}}}, 500
    assert_receive {:notify_action, {:system_ended, task, :completed}}, 500
    assert task.conversation_id == sid
    assert task.run_id == "run-1"
  end

  test "mark_run_finished does not emit a second completion" do
    sid = "task-finish-#{System.unique_integer([:positive])}"
    {:ok, _} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue, run_id: "run-2")

    Session.broadcast_event(sid, :run_start, %{model: "fake"})
    assert_receive {:notify_action, {:update_running, %{running_count: 1}}}

    Session.broadcast_event(sid, :run_end, %{status: "completed", turns: 1})
    assert_receive {:notify_action, {:system_ended, _, :completed}}
    flush_notify()

    Session.mark_run_finished(sid)
    refute_receive {:notify_action, {:system_ended, _, _}}, 50
  end

  test "viewing the conversation suppresses the system completion" do
    sid = "task-view-#{System.unique_integer([:positive])}"
    Application.put_env(:handbeam, :runtime_notify_visible, true)
    TaskTracker.viewing(self(), sid)

    {:ok, _} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue, run_id: "run-3")
    Session.broadcast_event(sid, :run_start, %{model: "fake"})
    assert_receive {:notify_action, {:update_running, %{running_count: 1}}}

    Session.broadcast_event(sid, :run_end, %{status: "completed", turns: 1})
    assert_receive {:notify_action, {:update_running, %{running_count: 0}}}
    refute_received {:notify_action, {:system_ended, _, _}}
    refute_received {:notify_action, {:in_app_ended, _, _}}
  end

  test "tool modes track parallel calls and publish only visual changes" do
    sid = "task-modes-#{System.unique_integer([:positive])}"
    {:ok, _} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue, run_id: "run-modes")
    TaskTracker.subscribe()
    Session.broadcast_event(sid, :run_start, %{})
    assert_receive {:runtime_tasks, %{tasks: [%{mode: :run}]}}
    flush_notify()

    Session.broadcast_event(sid, :tool_start, %{tool: "read", tool_use_id: "read-1"})
    assert_receive {:runtime_tasks, %{tasks: [%{mode: :look}]}}
    Session.broadcast_event(sid, :tool_start, %{tool: "grep", tool_use_id: "read-2"})
    Session.snapshot(sid)
    assert [%{mode: :look} = task] = TaskTracker.snapshot().tasks
    refute Map.has_key?(task, :tools)
    refute_receive {:runtime_tasks, _}, 30

    Session.broadcast_event(sid, :tool_start, %{tool: "write", tool_use_id: "write-1"})
    assert_receive {:runtime_tasks, %{tasks: [%{mode: :edit}]}}
    Session.broadcast_event(sid, :tool_end, %{tool_use_id: "read-1"})
    Session.snapshot(sid)
    assert [%{mode: :edit}] = TaskTracker.snapshot().tasks
    refute_receive {:runtime_tasks, _}, 30
    Session.broadcast_event(sid, :tool_end, %{tool_use_id: "write-1"})
    assert_receive {:runtime_tasks, %{tasks: [%{mode: :look}]}}
    Session.broadcast_event(sid, :tool_start, %{tool: "bash", tool_use_id: "bash-1"})
    assert_receive {:runtime_tasks, %{tasks: [%{mode: :run}]}}
    Session.broadcast_event(sid, :tool_end, %{tool_use_id: "bash-1"})
    assert_receive {:runtime_tasks, %{tasks: [%{mode: :look}]}}
    Session.broadcast_event(sid, :tool_end, %{tool_use_id: "read-2"})
    assert_receive {:runtime_tasks, %{tasks: [%{mode: :run}]}}
    refute_receive {:notify_action, _}, 30

    Session.broadcast_event(sid, :run_end, %{status: "completed"})
    assert_receive {:runtime_tasks, %{tasks: []}}
    Handbeam.SessionSupervisor.stop_session(sid)
  end

  test "tool lifecycle is compact, run-scoped, and survives approval without stale modes" do
    sid = "task-scope-#{System.unique_integer([:positive])}"
    {:ok, _} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue, run_id: "run-current")
    Phoenix.PubSub.subscribe(Handbeam.PubSub, "runtime:runs")
    TaskTracker.subscribe()
    Session.broadcast_event(sid, :run_start, %{})
    assert_receive {:runtime_tasks, _}

    Session.broadcast_event(sid, :tool_start, %{
      tool: "edit",
      tool_use_id: "edit-1",
      input: %{content: "private input"}
    })

    assert_receive {:tool_lifecycle, ^sid, :tool_start, payload}
    assert payload == %{run_id: "run-current", tool: "edit", tool_use_id: "edit-1"}
    assert_receive {:runtime_tasks, %{tasks: [%{mode: :edit}]}}

    send(
      TaskTracker,
      {:tool_lifecycle, sid, :tool_end, %{run_id: "old-run", tool_use_id: "edit-1"}}
    )

    assert [%{mode: :edit}] = TaskTracker.snapshot().tasks
    refute_receive {:runtime_tasks, _}, 30

    Session.broadcast_event(sid, :tool_approval_requested, %{})
    assert_receive {:runtime_tasks, %{tasks: [%{status: :waiting_confirmation}]}}
    Session.broadcast_event(sid, :tool_end, %{tool_use_id: "edit-1"})
    Session.snapshot(sid)
    assert [%{status: :waiting_confirmation, mode: :run}] = TaskTracker.snapshot().tasks
    refute_receive {:runtime_tasks, _}, 30
    Session.broadcast_event(sid, :run_resumed, %{})
    assert_receive {:runtime_tasks, %{tasks: [%{status: :running, mode: :run}]}}
    Session.broadcast_event(sid, :run_end, %{status: "cancelled"})
    assert_receive {:runtime_tasks, %{tasks: []}}
    Session.broadcast_event(sid, :tool_start, %{tool: "read", tool_use_id: "late"})
    Session.snapshot(sid)
    assert TaskTracker.snapshot().tasks == []
    Handbeam.SessionSupervisor.stop_session(sid)
  end

  defp flush_notify do
    receive do
      {:notify_action, _} -> flush_notify()
    after
      20 -> :ok
    end
  end
end

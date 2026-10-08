defmodule Handbeam.ScheduleTest do
  use Handbeam.DataCase, async: false

  alias Handbeam.Agent.{Config, Message, State}
  alias Handbeam.Agent.Middleware.ToolGuard
  alias Handbeam.ConversationStore
  alias Handbeam.Permissions.ToolPolicy
  alias Handbeam.Schedule.{Clock, Entry, Rule, Run, Store}
  alias Handbeam.Tool.Builtin.Schedule, as: ScheduleTool

  @zone "Asia/Shanghai"
  @ny "America/New_York"

  setup do
    on_exit(fn -> Application.delete_env(:handbeam, :schedule_now) end)
    :ok
  end

  test "spring gap uses the first valid instant and fall overlap uses the earlier one" do
    rule = weekly([7], ["02:30"])
    before_gap = ~U[2026-03-08 06:00:00Z]

    assert {:ok, next} = Rule.next_after(rule, @ny, before_gap)
    assert DateTime.to_iso8601(next) == "2026-03-08T07:00:00Z"

    rule = weekly([7], ["01:30"])
    before_overlap = ~U[2026-11-01 04:00:00Z]
    assert {:ok, earlier} = Rule.next_after(rule, @ny, before_overlap)
    assert DateTime.to_iso8601(earlier) == "2026-11-01T05:30:00Z"
  end

  test "interval next time is strict and one minute is legal" do
    rule = %{"kind" => "interval", "every_minutes" => 1}
    now = ~U[2026-07-18 00:00:00Z]
    assert {:ok, next} = Rule.next_after(rule, @zone, now)
    assert DateTime.diff(next, now) == 60
    assert {:error, :invalid_interval} = Rule.validate(%{"kind" => "interval", "every_minutes" => 0})
  end

  test "saving a schedule does not create a run" do
    now = ~U[2026-07-18 01:00:00Z]
    {:ok, entry} = create_schedule(now)

    assert entry.next_run_at == ~U[2026-07-18 01:01:00Z]
    assert Store.recent_runs(entry.id) == []
    assert Clock.tick(now) == :ok
    assert Store.recent_runs(entry.id) == []
  end

  test "concurrent claim keeps one slot" do
    now = ~U[2026-07-18 02:00:00Z]
    {:ok, entry} = create_schedule(DateTime.add(now, -60, :second))

    results =
      1..8
      |> Task.async_stream(fn _ -> Store.claim(entry, now) end, max_concurrency: 8)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :conflict} or &1 == {:error, :already_claimed})) == 7
  end

  test "a missed window claims only the latest slot and records the skip" do
    due = ~U[2026-07-18 03:00:00Z]
    {:ok, entry} = create_schedule(due)
    later = DateTime.add(due, 5 * 60, :second)

    assert {:ok, claim} = Store.claim(entry, later)
    assert claim.missed == 5
    assert claim.run.kind == "catch_up"
    assert claim.run.slot_at == DateTime.add(due, 5 * 60, :second)
    assert claim.skipped.status == "skipped"
    assert claim.skipped.reason =~ "missed:5"
  end

  test "pause, update, and a failed slot do not fire again" do
    now = ~U[2026-07-18 04:00:00Z]
    {:ok, entry} = create_schedule(now)

    assert {:ok, paused} = Store.pause(entry, now)
    assert Clock.tick(DateTime.add(now, 120, :second)) == :ok
    assert Store.recent_runs(paused.id) == []

    assert {:ok, resumed} = Store.resume(paused, now)
    assert resumed.next_run_at == DateTime.add(now, 60, :second)
    assert {:ok, updated} = Store.update(resumed, %{name: "renamed"}, now)
    assert updated.next_run_at == resumed.next_run_at
    assert Store.recent_runs(updated.id) == []

    assert {:ok, claim} = Store.claim(updated, updated.next_run_at)
    assert {:ok, failed} = Store.record(claim.run, "failed", reason: "provider")
    assert Clock.tick(updated.next_run_at) == :ok
    assert Enum.count(Store.recent_runs(updated.id), &(&1.slot_at == failed.slot_at)) == 1
  end

  test "a claimed run that never finishes becomes unknown and is not retried" do
    now = ~U[2026-07-18 05:00:00Z]
    {:ok, entry} = create_schedule(now)
    assert {:ok, claim} = Store.claim(entry, entry.next_run_at)

    assert [%Run{status: "unknown"}] =
             Store.recover_unknown(DateTime.add(now, 120, :second), fn _, _ -> false end)

    assert Clock.tick(DateTime.add(now, 180, :second)) == :ok
    assert Enum.count(Store.recent_runs(entry.id), &(&1.status == "unknown")) == 1
    refute Enum.any?(Store.recent_runs(entry.id), &(&1.status == "claimed"))
  end

  test "an archived conversation disables the schedule" do
    now = ~U[2026-07-18 06:00:00Z]
    {:ok, entry} = create_schedule(now)
    {:ok, _} = ConversationStore.archive(entry.conversation_id)

    assert Clock.tick(entry.next_run_at) == :ok
    assert {:ok, disabled} = Store.get(entry.id)
    assert disabled.status == "disabled"
    assert [%Run{status: "skipped", reason: "conversation_unavailable"}] = Store.recent_runs(entry.id)
  end

  test "a scheduled source cannot change a schedule and another conversation is hidden" do
    now = ~U[2026-07-18 07:00:00Z]
    {:ok, entry} = create_schedule(now)
    context = %{conversation_id: entry.conversation_id, workspace_id: entry.workspace_id, source: :schedule}

    assert {:error, "schedule_changes_require_user_turn"} =
             ScheduleTool.execute(%{"action" => "pause", "id" => entry.id}, context)

    other = %{context | conversation_id: "other-conversation", source: :live_view}

    assert {:error, "not_found"} =
             ScheduleTool.execute(%{"action" => "get", "id" => entry.id}, other)
  end

  test "schedule writes prompt unless they are status-only or yolo" do
    policy = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "auto"}})
    yolo = ToolPolicy.from_settings(%{"tools" => %{"default_mode" => "yolo"}})

    assert ToolPolicy.decision(policy, call("create", %{"rule" => %{}})) == :prompt
    assert ToolPolicy.decision(policy, call("run_now", %{})) == :prompt
    assert ToolPolicy.decision(policy, call("update", %{"rule" => %{}})) == :prompt
    assert ToolPolicy.decision(policy, call("pause", %{})) == :auto
    assert ToolPolicy.decision(yolo, call("create", %{"rule" => %{}})) == :auto
  end

  test "a scheduled run halts instead of waiting for approval" do
    config = %Config{
      working_directory: System.tmp_dir!(),
      model: "fake",
      middleware: [],
      source: :schedule
    }

    state =
      %State{State.init(config, "hi") | tool_guard_overrides: %{}}
      |> State.append_messages([
        Message.tool_use([%{type: "tool_use", id: "c1", name: "computer", input: %{}}])
      ])

    assert {:tool_guard_denied, halted} = ToolGuard.call(:after_tool_request, state)
    assert halted.status == :halted
    assert halted.error =~ "computer"
  end

  test "three Asia/Shanghai days claim each daily and interval slot once" do
    start = ~U[2026-07-20 00:00:00Z]

    {:ok, daily} =
      create_schedule(start,
        rule: weekly([1, 2, 3, 4, 5, 6, 7], ["09:00"]),
        conversation_id: unique_id("daily")
      )

    {:ok, interval} =
      create_schedule(start,
        rule: %{"kind" => "interval", "every_minutes" => 12 * 60},
        conversation_id: unique_id("interval")
      )

    Enum.each(0..(3 * 24), fn hour ->
      assert :ok = Clock.tick(DateTime.add(start, hour * 3600, :second))
    end)

    daily_slots = Store.recent_runs(daily.id) |> Enum.map(& &1.slot_at) |> Enum.reject(&is_nil/1)
    interval_slots = Store.recent_runs(interval.id) |> Enum.map(& &1.slot_at) |> Enum.reject(&is_nil/1)

    assert length(daily_slots) == 3
    assert daily_slots == Enum.uniq(daily_slots)
    assert length(interval_slots) == 6
    assert interval_slots == Enum.uniq(interval_slots)
  end

  defp create_schedule(now, extra \\ []) do
    id = Keyword.get(extra, :conversation_id, unique_id("sched"))
    {:ok, _} = ConversationStore.create("default", id: id, title: "Schedule")
    Application.put_env(:handbeam, :schedule_now, fn -> now end)

    Store.create(%{
      workspace_id: "default",
      conversation_id: id,
      name: "digest",
      instruction: "summarize",
      rule: Keyword.get(extra, :rule, %{"kind" => "interval", "every_minutes" => 1}),
      time_zone: @zone,
      model: "fake/model",
      created_by: "user"
    })
  end

  defp weekly(days, times), do: %{"kind" => "weekly", "weekdays" => days, "times" => times}

  defp call(action, input) do
    %{id: "call", name: "schedule", input: Map.put(input, "action", action)}
  end

  defp unique_id(prefix), do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
end

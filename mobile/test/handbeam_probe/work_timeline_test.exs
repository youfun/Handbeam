defmodule HandbeamProbe.WorkTimelineTest do
  use ExUnit.Case, async: true
  use Gettext, backend: HandbeamProbe.Gettext
  alias HandbeamProbe.WorkTimeline

  defp tool(id, name, status \\ "done", input \\ %{}) do
    %{
      "id" => id,
      "content_type" => "tool",
      "tool" => name,
      "tool_status" => status,
      "input" => input
    }
  end

  defp assistant(id, phase) do
    %{"id" => id, "content_type" => "assistant_msg", "phase" => phase, "content" => id}
  end

  test "normal completion hides commentary and tools but not final response" do
    entries = [
      assistant("plan", "commentary"),
      tool("read", "read"),
      assistant("answer", "final")
    ]

    [plan, read, answer] = WorkTimeline.project(entries)
    assert plan["work_segment_first"]
    assert plan["work_hidden"]
    assert read["work_hidden"]
    refute answer["work_hidden"]
    refute plan["work_boundary_summary"]
    assert WorkTimeline.project(entries) == WorkTimeline.project(WorkTimeline.project(entries))
  end

  test "incoming message during tool execution retains prior activity and isolates later tools" do
    user = %{"id" => "u", "content_type" => "user_msg", "interrupts_work" => true}
    entries = [tool("before", "bash", "running"), user, tool("after", "bash", "running")]
    [before, _, after_tool] = WorkTimeline.project(entries)
    assert before["work_hidden"]
    assert before["work_boundary_summary"]["work_summary"] == "Ran 1 command"
    refute after_tool["work_hidden"]
    refute before["work_segment_id"] == after_tool["work_segment_id"]

    late = List.update_at(entries, 0, &Map.put(&1, "tool_status", "error"))
    [before, _, after_tool] = WorkTimeline.project(late)
    assert before["work_boundary_summary"]["work_failed"] == 1
    assert before["id"] == "before"
    assert after_tool["id"] == "after"
  end

  test "delivery steer interrupts work; follow_up does not; missing delivery falls back" do
    steer = %{"id" => "u", "content_type" => "user_msg", "delivery" => "steer"}

    [before, _, after_tool] =
      WorkTimeline.project([
        tool("before", "bash", "running"),
        steer,
        tool("after", "bash", "running")
      ])

    assert before["work_boundary_summary"]
    refute before["work_segment_id"] == after_tool["work_segment_id"]

    follow = %{"id" => "u2", "content_type" => "user_msg", "delivery" => "follow_up"}

    [before_follow | _] =
      WorkTimeline.project([tool("b", "bash", "running"), follow, tool("a", "bash", "running")])

    refute before_follow["work_boundary_summary"]

    fallback = %{"id" => "u3", "content_type" => "user_msg", "interrupts_work" => true}

    [before_fb | _] =
      WorkTimeline.project([
        tool("b2", "bash", "running"),
        fallback,
        tool("a2", "bash", "running")
      ])

    assert before_fb["work_boundary_summary"]
  end

  test "missing final answer alone does not synthesize an interruption summary" do
    [entry] = WorkTimeline.project([tool("t", "bash")], %{}, %{"t" => false})
    assert entry["work_hidden"]
    refute entry["work_boundary_summary"]
  end

  test "activity groups cannot cross commentary or edits; guidance is separate" do
    entries = [
      tool("r", "read", "done", %{"file_path" => "lib/a.ex"}),
      tool("g", "read", "done", %{"file_path" => "sigil/AGENTS.md"}),
      tool("s", "file_search"),
      tool("e", "edit"),
      tool("r2", "read"),
      assistant("explanation", "commentary"),
      tool("r3", "read")
    ]

    result = WorkTimeline.project(entries)

    details =
      Enum.join(
        [
          ngettext("%{count} file", "%{count} files", 1),
          ngettext("%{count} guidance file", "%{count} guidance files", 1),
          ngettext("%{count} search", "%{count} searches", 1)
        ],
        ", "
      )

    assert hd(result)["work_summary"] == gettext("Explored %{details}", details: details)
    assert Enum.at(result, 3)["work_summary"] == gettext("Edited %{path}", path: "file")
    assert Enum.at(result, 4)["work_group_id"] == "r2"
    assert Enum.at(result, 6)["work_group_id"] == "r3"
  end

  test "manual segment, group and output choices survive running tool updates independently" do
    entries = [tool("t", "bash", "running")]
    [entry] = WorkTimeline.project(entries, %{"t" => false}, %{"t" => false}, %{"t" => true})
    assert entry["work_hidden"]
    assert entry["work_collapsed"]
    assert entry["tool_output_open"]
    [entry] = WorkTimeline.project(entries, %{"t" => false}, %{"t" => true}, %{"t" => true})
    refute entry["work_hidden"]
    assert entry["work_collapsed"]
    assert entry["tool_output_open"]
  end

  test "failure and cancellation counts are distinct and edits count diff lines" do
    [first, _, _] =
      WorkTimeline.project([
        tool("a", "bash", "error"),
        tool("b", "bash", "cancelled"),
        tool("c", "bash")
      ])

    assert first["work_summary"] == "Ran 3 commands"
    assert first["work_failed"] == 1
    assert first["work_cancelled"] == 1

    edit =
      tool("e", "edit")
      |> Map.put("diff_lines", [%{type: :ins}, %{"type" => "ins"}, %{"type" => "del"}])

    [edit] = WorkTimeline.project([edit])
    assert edit["work_added"] == 2
    assert edit["work_removed"] == 1
  end
end

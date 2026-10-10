defmodule Handbeam.Agent.ToolResultProjectionTest do
  use ExUnit.Case, async: true

  alias Handbeam.Agent.{Message, ToolResultProjection}

  @long String.duplicate("n", 2_500)
  @older String.duplicate("o", 2_500)

  setup do
    dir = Path.join(System.tmp_dir!(), "hb-projection-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "a steer after the latest tool result does not omit that result", %{dir: dir} do
    messages = [
      Message.assistant_blocks([
        %{type: "tool_use", id: "old", name: "bash", input: %{}}
      ]),
      Message.tool_results([
        %{type: "tool_result", tool_use_id: "old", content: @older}
      ]),
      Message.assistant_blocks([
        %{type: "tool_use", id: "new", name: "bash", input: %{}}
      ]),
      Message.tool_results([
        %{type: "tool_result", tool_use_id: "new", content: @long}
      ]),
      Message.user("steer: look at the new failure")
    ]

    stored = ToolResultProjection.persist(ToolResultProjection.retained(messages), dir)
    projected = ToolResultProjection.project(messages, stored)
    newest = List.last(Enum.at(projected, 3).content).content
    earlier = List.last(Enum.at(projected, 1).content).content

    assert newest == @long
    assert earlier =~ "Earlier tool result omitted"
    refute earlier =~ @older
  end

  test "an existing artifact is not reused when its bytes differ", %{dir: dir} do
    messages = earlier_result("call/1", @long)
    [keep] = ToolResultProjection.retained(messages)
    absolute = Path.expand(keep.relative, dir)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, "stale body")

    stored = ToolResultProjection.persist([keep], dir)
    assert stored[keep.id] == :error

    projected = ToolResultProjection.project(messages, stored)
    content = hd(Enum.at(projected, 1).content).content
    assert content =~ "Full body was not retained"
    refute content =~ "stale body"
  end

  test "a repeated tool call id with new content writes a different file", %{dir: dir} do
    first = earlier_result("call_1", @older)
    second = earlier_result("call_1", @long)

    stored_first = ToolResultProjection.persist(ToolResultProjection.retained(first), dir)
    stored_second = ToolResultProjection.persist(ToolResultProjection.retained(second), dir)

    [keep_first] = ToolResultProjection.retained(first)
    [keep_second] = ToolResultProjection.retained(second)

    assert keep_first.relative != keep_second.relative
    assert stored_first[keep_first.id] == :ok
    assert stored_second[keep_second.id] == :ok
    assert File.read!(Path.expand(keep_second.relative, dir)) == @long
    assert File.read!(Path.expand(keep_first.relative, dir)) == @older
  end

  defp earlier_result(id, content) do
    [
      Message.assistant_blocks([
        %{type: "tool_use", id: id, name: "bash", input: %{}}
      ]),
      Message.tool_results([
        %{type: "tool_result", tool_use_id: id, content: content}
      ]),
      Message.assistant("done"),
      Message.assistant_blocks([
        %{type: "tool_use", id: "latest", name: "bash", input: %{}}
      ]),
      Message.tool_results([
        %{type: "tool_result", tool_use_id: "latest", content: "short"}
      ])
    ]
  end
end

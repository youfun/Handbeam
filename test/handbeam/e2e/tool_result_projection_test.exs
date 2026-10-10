defmodule Handbeam.E2E.ToolResultProjectionTest do
  @moduledoc """
  Within one run, a later provider call keeps the newest tool result and
  replaces an older long result with a file pointer. The transcript still
  stores the original output.

  Run: mix test --include e2e test/handbeam/e2e/tool_result_projection_test.exs
  """

  use ExUnit.Case, async: false

  alias Handbeam.Agent.Coordinator
  alias Handbeam.Agent.Message
  alias Handbeam.ConversationStore
  alias Handbeam.ConversationTranscriptStore
  alias Handbeam.PubSub.Session
  alias Handbeam.TestSupport.E2EHarness

  @moduletag :e2e

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbeam.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbeam.Repo, {:shared, self()})

    %{workspace: workspace} = E2EHarness.isolate_home!("tool-result-projection")
    File.write!(Path.join(workspace, "old.txt"), String.duplicate("OLD-RESULT-BODY\n", 400))
    File.write!(Path.join(workspace, "new.txt"), "NEW-RESULT-BODY\n")
    %{workspace: workspace}
  end

  test "an earlier long tool result is omitted from the next provider call", %{
    workspace: workspace
  } do
    sid = "projection-e2e-#{System.unique_integer([:positive])}"
    {:ok, _} = ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)
    on_exit(fn -> E2EHarness.cancel!(sid) end)

    parent = self()

    script = fn messages, _defs ->
      send(parent, {:provider_messages, messages})
      rounds = Enum.count(messages, &match?(%Message{role: :tool_result}, &1))

      cond do
        rounds == 0 ->
          {:tools, [%{name: "read", input: %{"file_path" => "old.txt"}}]}

        rounds == 1 ->
          {:tools, [%{name: "read", input: %{"file_path" => "new.txt"}}]}

        true ->
          "done"
      end
    end

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "read both files",
               workspace_path: workspace,
               model: "fake/fake-model",
               provider: Handbeam.TestSupport.FakeProvider,
               provider_config: %{scenario: {:script, script}},
               tools: Handbeam.Agent.default_tools(),
               mcp: false,
               trusted_project?: true,
               source: :cli,
               streaming: false,
               max_turns: 4
             )

    assert_receive {:provider_messages, first}, 20_000
    assert tool_result_text(first) == ""

    assert_receive {:provider_messages, second}, 20_000
    assert tool_result_text(second) =~ "OLD-RESULT-BODY"
    refute tool_result_text(second) =~ "Earlier tool result omitted"

    assert_receive {:provider_messages, third}, 20_000
    assert tool_result_text(third) =~ "NEW-RESULT-BODY"
    assert tool_result_text(third) =~ "Earlier tool result omitted"
    assert tool_result_text(third) =~ ".handbeam/tool-results/kept-"
    refute tool_result_text(third) =~ "OLD-RESULT-BODY"

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 20_000

    {:ok, entries} = ConversationTranscriptStore.list(sid)

    old_read =
      Enum.find(entries, &(&1["tool_name"] == "read" and &1["output"] =~ "OLD-RESULT-BODY"))

    assert old_read["tool_status"] == "done"
    assert old_read["output"] =~ "OLD-RESULT-BODY"

    kept =
      workspace
      |> Path.join(".handbeam/tool-results")
      |> File.ls!()
      |> Enum.find(&String.starts_with?(&1, "kept-"))

    assert File.read!(Path.join([workspace, ".handbeam", "tool-results", kept])) =~
             "OLD-RESULT-BODY"
  end

  defp tool_result_text(messages) do
    messages
    |> Enum.filter(&match?(%Message{role: :tool_result}, &1))
    |> Enum.map_join("\n", fn
      %Message{content: blocks} when is_list(blocks) ->
        Enum.map_join(blocks, "\n", fn block ->
          to_string(block[:content] || block["content"] || "")
        end)

      %Message{content: content} when is_binary(content) ->
        content

      _ ->
        ""
    end)
  end
end

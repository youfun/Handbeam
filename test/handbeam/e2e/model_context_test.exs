defmodule Handbeam.E2E.ModelContextTest do
  @moduledoc """
  The model-facing copy can shrink inside one run. The transcript keeps the
  original tool output.

  A provider input above the default window minus 16_384 compacts that copy
  even when the message text itself is far smaller. `read_context` shows the
  copy. `edit_context` replaces one exact span and leaves the original task.

  Run: mix test --include e2e test/handbeam/e2e/model_context_test.exs
  """

  use ExUnit.Case, async: false

  alias Handbeam.Agent.Config
  alias Handbeam.Agent.Coordinator
  alias Handbeam.Agent.Message
  alias Handbeam.ConversationStore
  alias Handbeam.ConversationTranscriptStore
  alias Handbeam.PubSub.Session
  alias Handbeam.TestSupport.E2EHarness
  alias Handbeam.TestSupport.FakeProvider

  @moduletag :e2e

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbeam.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbeam.Repo, {:shared, self()})

    %{workspace: workspace} = E2EHarness.isolate_home!("model-context")
    %{workspace: workspace}
  end

  test "a measured provider input compacts the next request", %{workspace: workspace} do
    assert_measured_input_compacts(workspace, %{input_tokens: 190_000, output_tokens: 20})
  end

  test "a cache hit compacts the next request", %{workspace: workspace} do
    assert_measured_input_compacts(workspace, %{
      input_tokens: 1_000,
      cache_read_input_tokens: 180_000,
      cache_creation_input_tokens: 9_000,
      output_tokens: 20
    })
  end

  defp assert_measured_input_compacts(workspace, usage) do
    body = "HEAD-MARKER\n" <> String.duplicate("BIG-RESULT-BODY\n", 3_000)
    File.write!(Path.join(workspace, "big.txt"), body)
    parent = self()

    script = fn messages, _defs ->
      send(parent, {:provider_messages, joined(messages)})
      text = joined(messages)
      rounds = Enum.count(messages, &match?(%Message{role: :tool_result}, &1))

      cond do
        text =~ "CONTEXT CHECKPOINT COMPACTION" ->
          "Goal\ncontinue"

        text =~ "Previous analysis summary" ->
          "done"

        rounds == 0 ->
          {:tools, [%{name: "read", input: %{"file_path" => "big.txt"}}], usage}

        true ->
          "done"
      end
    end

    sid = start_run!(workspace, "read big.txt", script, compaction: %{keep_recent_tokens: 200})

    assert_receive {:provider_messages, first}, 20_000
    refute first =~ "Previous analysis summary"
    refute first =~ "HEAD-MARKER"

    assert_receive {:provider_messages, summary_request}, 20_000
    assert summary_request =~ "CONTEXT CHECKPOINT COMPACTION"
    assert summary_request =~ "HEAD-MARKER"
    assert byte_size(summary_request) < 200_000

    assert_receive {:provider_messages, compacted}, 20_000
    assert compacted =~ "Previous analysis summary"
    assert compacted =~ "Goal"
    assert compacted =~ "read big.txt"

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 20_000
    assert transcript_output(sid, "read") =~ "HEAD-MARKER"
  end

  test "edit_context drops one log span and keeps the plan", %{workspace: workspace} do
    File.write!(Path.join(workspace, "old.txt"), "PLAN: keep this\nUNIQUE-OLD-LOG\n")
    parent = self()

    script = fn messages, defs ->
      send(parent, {:provider_messages, messages})
      send(parent, {:provider_roles, Enum.map(messages, & &1.role)})
      send(parent, {:tool_names, Enum.map(defs, & &1[:name])})
      text = joined(messages)

      cond do
        text =~ "kept-skeleton" ->
          "done"

        text =~ "[[ctx:" ->
          {:tools,
           [
             %{
               name: "edit_context",
               input: %{"old_text" => "UNIQUE-OLD-LOG", "new_text" => "kept-skeleton"}
             }
           ]}

        Enum.any?(messages, &match?(%Message{role: :tool_result}, &1)) ->
          {:tools, [%{name: "read_context", input: %{}}]}

        true ->
          {:tools, [%{name: "read", input: %{"file_path" => "old.txt"}}]}
      end
    end

    prompt =
      workspace
      |> run_opts(script)
      |> Config.from_opts()
      |> Map.fetch!(:system_prompt)

    assert prompt =~ "You own the context sent on later requests in this run."
    assert prompt =~ "read_context"
    assert prompt =~ "edit_context"

    sid = start_run!(workspace, "read old.txt", script)

    assert_receive {:provider_messages, _first}, 20_000
    assert_receive {:provider_roles, _first_roles}, 20_000
    assert_receive {:tool_names, names}, 20_000
    assert "read_context" in names
    assert "edit_context" in names
    refute "revise_context" in names

    assert_receive {:provider_messages, second}, 20_000
    assert_receive {:provider_roles, _second_roles}, 20_000
    assert_receive {:tool_names, _names}, 20_000
    assert joined(second) =~ "UNIQUE-OLD-LOG"
    assert joined(second) =~ "PLAN: keep this"

    assert_receive {:provider_messages, view}, 20_000
    assert_receive {:provider_roles, _view_roles}, 20_000
    assert_receive {:tool_names, _names}, 20_000
    view_text = joined(view)
    assert view_text =~ "[[ctx:0 user frozen]]"
    assert view_text =~ "read old.txt"
    assert view_text =~ "UNIQUE-OLD-LOG"
    assert view_text =~ "PLAN: keep this"

    assert_receive {:provider_messages, edited}, 20_000
    assert_receive {:provider_roles, edited_roles}, 20_000
    assert_receive {:tool_names, _names}, 20_000
    edited_text = joined(edited)
    assert edited_text =~ "read old.txt"
    assert edited_text =~ "PLAN: keep this"
    assert edited_text =~ "kept-skeleton"
    assert tool_result_text(edited) =~ "kept-skeleton"
    assert tool_result_text(edited) =~ "PLAN: keep this"
    refute tool_result_text(edited) =~ "UNIQUE-OLD-LOG"
    refute tool_call_text(edited) =~ "UNIQUE-OLD-LOG"
    refute edited_text =~ "Previous analysis summary"
    refute consecutive_users?(edited_roles)

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: :completed}}}, 20_000
    assert transcript_output(sid, "read") =~ "UNIQUE-OLD-LOG"
    assert transcript_output(sid, "read") =~ "PLAN: keep this"
  end

  defp start_run!(workspace, text, script, extra \\ []) do
    sid = "model-context-e2e-#{System.unique_integer([:positive])}"
    {:ok, _} = ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)
    on_exit(fn -> E2EHarness.cancel!(sid) end)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, text, run_opts(workspace, script) ++ extra)

    sid
  end

  defp run_opts(workspace, script) do
    [
      workspace_path: workspace,
      model: "fake/fake-model",
      provider: FakeProvider,
      provider_config: %{scenario: {:script, script}},
      tools: Handbeam.Agent.default_tools(),
      mcp: false,
      trusted_project?: true,
      source: :cli,
      streaming: false,
      max_turns: 6
    ]
  end

  defp transcript_output(sid, tool_name) do
    {:ok, entries} = ConversationTranscriptStore.list(sid)

    entries
    |> Enum.find(&(&1["tool_name"] == tool_name))
    |> Map.fetch!("output")
  end

  defp consecutive_users?(roles) do
    roles
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(&(&1 == [:user, :user]))
  end

  defp tool_result_text(messages) do
    messages
    |> Enum.filter(&match?(%Message{role: :tool_result}, &1))
    |> joined()
  end

  defp tool_call_text(messages) do
    messages
    |> Enum.flat_map(fn
      %Message{role: :assistant, content: blocks} when is_list(blocks) ->
        Enum.map(blocks, fn block ->
          input = block[:input] || block["input"]
          if is_map(input), do: inspect(input), else: ""
        end)

      _ ->
        []
    end)
    |> Enum.join("\n")
  end

  defp joined(messages) do
    Enum.map_join(messages, "\n", fn
      %Message{content: content} when is_binary(content) ->
        content

      %Message{content: blocks} when is_list(blocks) ->
        Enum.map_join(blocks, "\n", fn block ->
          to_string(block[:content] || block["content"] || block[:text] || "")
        end)

      _ ->
        ""
    end)
  end
end

defmodule HandbeamWeb.Feature.SubagentDmFeatureTest do
  @moduledoc """
  PhoenixTest feature test for direct messages to a subagent from the
  workspace composer: `@<subagent_type or child id> text` is routed to the
  subagent instead of the parent conversation; anything else stays a normal
  message.

  Run: mix test test/feature/subagent_dm_feature_test.exs
  """

  use HandbeamWeb.FeatureCase, async: false

  alias Handbeam.Agent.{Coordinator, Delegation, Message}
  alias Handbeam.ConversationStore
  alias Handbeam.PubSub.Session

  @moduletag :e2e

  defp isolate_home! do
    old_home = System.get_env("HOME")
    old_models = System.get_env("HANDBEAM_MODELS_FILE")

    root =
      Path.join(System.tmp_dir!(), "subagent-dm-feature-#{System.unique_integer([:positive])}")

    home = Path.join(root, "home")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(home)
    File.mkdir_p!(workspace)

    File.write!(
      Path.join(root, "models.json"),
      ~s({"providers": {"fake": {"baseUrl": "http://localhost", "api": "openai-chat-completions", "apiKey": "sk-fake", "models": [{"id": "fake-model", "name": "Fake Model"}]}}})
    )

    System.put_env("HOME", home)
    System.put_env("HANDBEAM_MODELS_FILE", Path.join(root, "models.json"))

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")

      if old_models,
        do: System.put_env("HANDBEAM_MODELS_FILE", old_models),
        else: System.delete_env("HANDBEAM_MODELS_FILE")

      File.rm_rf(root)
    end)

    %{workspace: workspace}
  end

  # Parent delegates once, then answers once the report arrives; the child
  # answers with the last user line it sees.
  defp script do
    fn messages, defs ->
      text = messages |> Enum.map_join("\n", &Message.text/1)
      child? = "task" not in Enum.map(defs, & &1.name)

      cond do
        child? ->
          "child says: " <> (text |> String.split("\n") |> List.last())

        text =~ "Background subagent report" ->
          "parent saw report"

        Enum.count(messages, &match?(%Message{role: :tool_result}, &1)) == 0 ->
          {:tools, [%{name: "task", input: %{"task" => "investigate", "criteria" => "one line"}}]}

        true ->
          "dispatched"
      end
    end
  end

  defp start_parent(sid, workspace) do
    {:ok, _} =
      Coordinator.add_message(sid, "delegate the work",
        workspace_path: workspace,
        model: "fake/fake-model",
        provider: Handbeam.TestSupport.FakeProvider,
        provider_config: %{scenario: {:script, script()}},
        tools: Handbeam.Agent.default_tools(),
        source: :cli,
        streaming: false
      )

    receive do
      {:agent_event, %{kind: :subagent_end, payload: %{status: :completed} = payload}} -> payload
    after
      15_000 -> flunk("subagent never finished")
    end
  end

  defp await_parent_report(sid) do
    receive do
      {:agent_event, %{kind: :run_end, payload: %{status: status}}} when status != :interrupted ->
        texts =
          for %{"role" => "assistant", "content" => content} <- transcript(sid), do: content

        if Enum.any?(texts, &String.contains?(&1, "parent saw report")),
          do: :ok,
          else: await_parent_report(sid)
    after
      15_000 -> flunk("parent never saw the report: #{inspect(transcript(sid))}")
    end
  end

  defp transcript(id) do
    {:ok, entries} = ConversationStore.load_messages_result(id)
    entries
  end

  # Drains Delegation and runners so nothing writes under the temp HOME after
  # on_exit restores it.
  defp settle(ids, attempts \\ 200) do
    state = :sys.get_state(Delegation)

    busy? =
      state.jobs != %{} or state.reports != %{} or
        Enum.any?(ids, &(Registry.lookup(Handbeam.AgentRunRegistry, &1) != []))

    if busy? and attempts > 0 do
      receive after: (20 -> settle(ids, attempts - 1))
    else
      :ok
    end
  end

  test "@subagent text in the composer goes to the subagent, not the parent", %{conn: conn} do
    %{workspace: workspace} = isolate_home!()
    sid = "dm-feature-#{System.unique_integer([:positive])}"
    {:ok, _} = ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    child = start_parent(sid, workspace).child_conversation_id
    await_parent_report(sid)

    conn
    |> visit("/w/default/c/#{sid}")
    |> fill_in("#ai-input", "Message", with: "@researcher what did you find?", exact: false)
    |> click_button("#send-button", "")
    |> assert_has("textarea#ai-input", "")
    |> assert_has("#flash-group", "follow-up")

    child_entries = transcript(child)

    assert Enum.any?(
             child_entries,
             &(&1["role"] == "user" and &1["content"] == "what did you find?")
           )

    refute Enum.any?(
             transcript(sid),
             &(&1["role"] == "user" and &1["content"] =~ "what did you find?")
           )

    # Let the follow-up run finish so nothing writes under the temp HOME after
    # on_exit restores it.
    receive do
      {:agent_event, %{kind: :subagent_end, payload: %{kind: :dm, status: :completed}}} -> :ok
    after
      15_000 -> flunk("subagent follow-up never finished")
    end

    assert Enum.any?(
             transcript(child),
             &(&1["role"] == "assistant" and &1["content"] =~ "what did you find?")
           )

    settle([sid, child])
  end

  test "@name with no matching subagent stays a normal message", %{conn: conn} do
    isolate_home!()

    conn
    |> visit("/")
    |> fill_in("#ai-input", "Message", with: "@nobody hi there", exact: false)
    |> click_button("#send-button", "")
    |> assert_has(".msg-bubble.msg-user", "@nobody hi there")
    |> refute_has("#flash-group", "subagent")
  end
end

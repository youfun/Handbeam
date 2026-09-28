defmodule Handbeam.E2E.ProgressWatchdogTest do
  @moduledoc """
  An interactive run may exceed its configured watchdog window while it keeps
  streaming progress. The final answer and terminal status must remain durable.

  Run: mix test --include e2e test/handbeam/e2e/progress_watchdog_test.exs
  """

  use ExUnit.Case, async: false

  alias Handbeam.Agent.Coordinator
  alias Handbeam.ConversationStore
  alias Handbeam.PubSub.Session
  alias Handbeam.TestSupport.E2EHarness

  @moduletag :e2e

  defmodule ProgressProvider do
    @behaviour Handbeam.Agent.Provider

    @impl true
    def complete(messages, tool_defs, config),
      do: stream(messages, tool_defs, config, fn _ -> :ok end)

    @impl true
    def stream(_messages, _tool_defs, _config, on_chunk) do
      Enum.each(["still ", "working ", "done"], fn chunk ->
        receive do
        after
          150 -> on_chunk.(chunk)
        end
      end)

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbeam.Agent.Message.assistant("still working done")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{}
       }}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbeam.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbeam.Repo, {:shared, self()})
    :ok
  end

  test "streaming progress keeps an interactive run alive beyond one watchdog window" do
    %{workspace: workspace} = E2EHarness.isolate_home!("progress-watchdog")
    {:ok, conversation} = ConversationStore.create("progress-watchdog")
    id = conversation["id"]
    :ok = Session.subscribe(id)

    ExUnit.Callbacks.on_exit(fn -> E2EHarness.cancel!(id) end)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(id, "keep working",
               workspace_path: workspace,
               model: "fake-model",
               provider: ProgressProvider,
               provider_config: %{},
               tools: [],
               source: :live_view,
               timeout_ms: 250,
               streaming: true
             )

    assert_receive {:agent_event, %{kind: :run_start}}, 1_000
    assert [{index, _metadata}] = Registry.lookup(ExFff.Registry, Path.expand(workspace))
    assert Process.alive?(index)

    payload = E2EHarness.await_run_end(id)
    assert payload[:status] in ["completed", :completed]

    assert Enum.any?(
             E2EHarness.transcript(id),
             &(&1["role"] == "assistant" and &1["content"] == "still working done")
           )
  end
end

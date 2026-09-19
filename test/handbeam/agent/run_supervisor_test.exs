defmodule Handbeam.Agent.RunSupervisorTest do
  use ExUnit.Case, async: false

  alias Handbeam.Agent.Coordinator
  alias Handbeam.Agent.CandidateQueue

  defmodule BlockingProvider do
    @behaviour Handbeam.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, config) do
      send(Map.fetch!(config, :notify), {:run_supervisor_provider_started, self()})

      receive do
        :finish ->
          {:ok, %{stop_reason: :end_turn, messages: [], usage: %{}, response_metadata: %{}}}
      after
        5_000 -> raise "timeout"
      end
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        workspace_path: File.cwd!(),
        model: "fake-model",
        provider: BlockingProvider,
        provider_config: %{notify: self()},
        tools: [],
        source: :cli,
        streaming: false,
        max_turns: 3
      ],
      extra
    )
  end

  test "queue lifecycle is bound to run and stale queue is sealed after cancel" do
    sid = "run-supervisor-#{System.unique_integer([:positive])}"

    assert {:ok, %{action: :started}} = Coordinator.add_message(sid, "hello", opts())
    assert_receive {:run_supervisor_provider_started, _task_pid}
    assert {:ok, %{queue_pid: queue}} = Coordinator.status(sid)

    assert :ok = CandidateQueue.enqueue(queue, "while running", deliver_as: :steer)
    assert :ok = Coordinator.cancel(sid)

    assert_eventually(fn ->
      assert {:error, :sealed} = CandidateQueue.enqueue(queue, "late", deliver_as: :steer)
    end)
  end

  test "same conversation allows at most one active run" do
    sid = "run-singleton-#{System.unique_integer([:positive])}"

    assert {:ok, %{action: :started}} = Coordinator.start_run(sid, "one", opts())
    assert_receive {:run_supervisor_provider_started, _task_pid}

    assert {:error, :run_in_progress} = Coordinator.start_run(sid, "two", opts())
    assert :ok = Coordinator.cancel(sid)
  end

  test "completed run releases conversation for a later run" do
    sid = "run-restart-#{System.unique_integer([:positive])}"

    assert {:ok, %{action: :started}} =
             Coordinator.start_run(
               sid,
               "one",
               opts(
                 provider: Handbeam.TestSupport.FakeProvider,
                 provider_config: %{scenario: :simple_answer}
               )
             )

    assert_eventually(fn ->
      assert {:ok, %{running?: false}} = Coordinator.status(sid)
    end)

    assert {:ok, %{action: :started}} =
             Coordinator.start_run(
               sid,
               "two",
               opts(
                 provider: Handbeam.TestSupport.FakeProvider,
                 provider_config: %{scenario: :simple_answer}
               )
             )

    assert_eventually(fn ->
      assert {:ok, %{running?: false}} = Coordinator.status(sid)
    end)
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
  end
end

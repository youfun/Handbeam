defmodule Handbeam.Agent.RunnerTest do
  use ExUnit.Case, async: false

  alias Handbeam.Agent.Coordinator
  alias Handbeam.Agent.TranscriptPersistence
  alias Handbeam.PubSub.Session

  setup do
    old_home = System.get_env("HOME")
    home_dir = Path.join(System.tmp_dir!(), "sigil_runner_home_#{Ecto.UUID.generate()}")
    File.mkdir_p!(home_dir)
    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      File.rm_rf!(home_dir)
    end)

    :ok
  end

  defmodule FailingAssistantStore do
    alias Handbeam.ConversationTranscriptStore.ConversationStore, as: Store

    def append(_id, %{"role" => "assistant"}, _opts), do: {:error, :enospc}
    defdelegate append(id, entry, opts), to: Store
    defdelegate update(id, entry_id, patch, opts), to: Store
  end

  defmodule BlockingProvider do
    @behaviour Handbeam.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, config) do
      notify = Map.fetch!(config, :notify)
      send(notify, {:blocking_provider_started, self()})

      receive do
        :finish ->
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Handbeam.Agent.Message.assistant("done")],
             usage: %{input_tokens: 1, output_tokens: 1},
             response_metadata: %{}
           }}
      after
        5_000 ->
          raise "blocking provider timed out"
      end
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defmodule CrashProvider do
    @behaviour Handbeam.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config), do: raise("runner crash")

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defmodule StreamingProvider do
    @behaviour Handbeam.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config) do
      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbeam.Agent.Message.assistant("streamed")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{}
       }}
    end

    @impl true
    def stream(_messages, _tool_defs, _config, on_chunk) do
      on_chunk.("streamed")

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbeam.Agent.Message.assistant("streamed")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{}
       }}
    end
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        workspace_path: File.cwd!(),
        model: "fake-model",
        provider: Handbeam.TestSupport.FakeProvider,
        provider_config: %{scenario: :simple_answer},
        tools: [],
        source: :cli,
        streaming: false,
        max_turns: 3
      ],
      extra
    )
  end

  test "Coordinator.status/1 reports active Runner state" do
    sid = "runner-status-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started, run_pid: runner_pid}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(provider: BlockingProvider, provider_config: %{notify: self()})
             )

    assert_receive {:blocking_provider_started, _task_pid}

    assert {:ok, %{running?: true, status: :running, run_pid: ^runner_pid, queue_pid: queue_pid}} =
             Coordinator.status(sid)

    assert is_pid(queue_pid)
    assert :ok = Coordinator.cancel(sid)
  end

  test "Coordinator.cancel/1 terminates active run and marks session idle" do
    sid = "runner-cancel-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(provider: BlockingProvider, provider_config: %{notify: self()})
             )

    assert_receive {:blocking_provider_started, _task_pid}
    assert :ok = Coordinator.cancel(sid)

    assert_eventually(fn ->
      assert {:ok, %{running?: false}} = Coordinator.status(sid)
    end)
  end

  test "cancel acknowledges completion before scheduling supervisor teardown" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default")
    sid = conversation["id"]

    assert {:ok, %{run_pid: runner}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(provider: BlockingProvider, provider_config: %{notify: self()})
             )

    assert_receive {:blocking_provider_started, _task_pid}
    ref = Process.monitor(runner)
    parent = self()
    supervisor = Handbeam.AgentRunTaskSupervisor
    :ok = :sys.suspend(supervisor)

    try do
      spawn_link(fn -> send(parent, {:cancel_result, Coordinator.cancel(sid)}) end)
      assert_receive {:cancel_result, :ok}, 1_000
      assert %{meta: %{running?: false}} = Session.snapshot(sid)
    after
      :sys.resume(supervisor)
    end

    assert_receive {:DOWN, ^ref, :process, ^runner, :shutdown}, 1_000
  end

  test "cancel marks durable in-flight tools after task shutdown" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    sid = conversation["id"]
    :ok = Session.subscribe(sid)

    assert {:ok, %{action: :started, run_id: run_id}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(provider: BlockingProvider, provider_config: %{notify: self()})
             )

    assert_receive {:blocking_provider_started, _task_pid}

    TranscriptPersistence.handle_event(
      sid,
      {:tool_start, %{tool_use_id: "hold-1", tool: "bash", input: %{command: "sleep"}}},
      run_id: run_id
    )

    assert :ok = Coordinator.cancel(sid)

    tool =
      Enum.find(Handbeam.ConversationStore.load_messages(sid), &(&1["id"] == "tool-hold-1"))

    assert tool["status"] == "cancelled"
    assert tool["tool_status"] == "cancelled"

    cancelled =
      sid
      |> Session.snapshot()
      |> Map.fetch!(:events)
      |> Enum.filter(fn
        %{kind: :run_end, payload: %{status: status}}
        when status in [:cancelled, "cancelled"] ->
          true

        _ ->
          false
      end)

    assert length(cancelled) == 1
  end

  test "task crash broadcasts run_end status error" do
    sid = "runner-crash-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "boom", opts(provider: CrashProvider))

    assert_eventually(fn ->
      %{events: events} = Session.snapshot(sid)
      assert Enum.any?(events, &match?(%{kind: :run_end, payload: %{status: "error"}}, &1))
    end)
  end

  test "assistant persistence failure ends the run as error, never completed" do
    sid = "runner-persistence-error-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "hello", opts(transcript_store: FailingAssistantStore))

    assert_receive {:agent_event, %{kind: :run_end, payload: %{status: "error", error: reason}}},
                   1_000

    assert reason =~ "Assistant transcript persistence failed"
    assert reason =~ "enospc"
    %{events: events} = Session.snapshot(sid)
    refute Enum.any?(events, &match?(%{kind: :run_end, payload: %{status: :completed}}, &1))

    assert [%{"role" => "user", "content" => "hello"}] =
             Handbeam.ConversationStore.load_messages(sid)
  end

  test "streaming coordinator run broadcasts message_delta into session" do
    sid = "runner-streaming-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(provider: StreamingProvider, provider_config: %{}, streaming: true)
             )

    assert_eventually(fn ->
      %{events: events} = Session.snapshot(sid)

      assert Enum.any?(
               events,
               &match?(%{kind: :message_delta, payload: %{chunk: "streamed"}}, &1)
             )

      assert Enum.any?(events, &match?(%{kind: :run_end}, &1))
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

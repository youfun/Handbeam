defmodule Handbeam.Agent.DelegationTest do
  use ExUnit.Case, async: false

  alias Handbeam.Agent.{Config, Coordinator, Delegation, Message, State}
  alias Handbeam.Agent.Delegation.Policy
  alias Handbeam.Agent.Tool.Executor
  alias Handbeam.ConversationStore

  defmodule BlockingProvider do
    @behaviour Handbeam.Agent.Provider
    def complete(messages, defs, config) do
      send(config.notify, {:provider, config.label, self(), messages, defs, config})

      receive do
        :crash ->
          exit(:deliberate_child_crash)

        :approval ->
          {:ok,
           %{
             stop_reason: :tool_use,
             messages: [
               Message.tool_use([
                 %{
                   type: "tool_use",
                   id: "read-call",
                   name: "read",
                   input: %{"path" => "sample.ex"}
                 }
               ])
             ],
             usage: %{input_tokens: 11, output_tokens: 2},
             response_metadata: %{}
           }}

        :finish ->
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Message.assistant("Evidence: lib/sample.ex:17")],
             usage: %{input_tokens: 7, output_tokens: 3},
             response_metadata: %{}
           }}
      end
    end

    def stream(messages, defs, config, _callback), do: complete(messages, defs, config)
  end

  setup do
    old_home = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "delegation-#{Ecto.UUID.generate()}")
    File.mkdir_p!(home)
    System.put_env("HOME", home)
    unless Process.whereis(Delegation), do: start_supervised!(Delegation)
    {:ok, parent} = ConversationStore.create("workspace")

    opts = [
      workspace_path: home,
      working_directory: home,
      workspace_id: "workspace",
      model: "fake",
      provider: BlockingProvider,
      provider_config: %{notify: self(), label: :parent},
      tools: [],
      source: :cli,
      middleware: [],
      mcp: false
    ]

    {:ok, ack} = Coordinator.add_message(parent["id"], "Parent secret not inherited", opts)
    assert_receive {:provider, :parent, _, _, _, _}, 2_000

    context = %{
      conversation_id: parent["id"],
      workspace_id: "workspace",
      run_id: ack.run_id,
      runner_pid: ack.run_pid,
      tool_call_id: "task-1",
      working_directory: home,
      tool_timeout: 60_000,
      authorized_tools: ["read", "write", "task"],
      delegation_config:
        Config.from_opts(opts |> Keyword.put(:provider_config, %{notify: self(), label: :child}))
    }

    on_exit(fn ->
      Coordinator.cancel(parent["id"])
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      File.rm_rf!(home)
    end)

    %{context: context, parent: parent}
  end

  defp delegate(context) do
    Task.async(fn ->
      Handbeam.Tool.Builtin.Task.execute(
        %{"task" => "Find evidence", "criteria" => "Include exact line", "background" => false},
        context
      )
    end)
  end

  test "deadline is half the outer timeout, capped, and low limits fail before startup" do
    assert Policy.budget(60_000) == {:ok, 30_000}
    assert Policy.budget(10_000) == {:ok, 5_000}
    assert Policy.budget(120_000) == {:ok, 45_000}
    assert {:error, _} = Policy.budget(3_999)
  end

  test "independent context, raw usage once, no visible child or notification", %{
    context: context,
    parent: parent
  } do
    task = delegate(context)
    assert_receive {:provider, :child, child, messages, defs, _}, 2_000
    assert Enum.map(defs, & &1.name) -- ["read"] == []
    refute Enum.any?(messages, &(Message.text(&1) =~ "Parent secret"))
    assert Enum.any?(messages, &(Message.text(&1) =~ "Include exact line"))
    assert ConversationStore.list() |> Enum.map(& &1["id"]) == [parent["id"]]

    [internal] =
      Enum.filter(ConversationStore.list(include_internal?: true), &ConversationStore.internal?/1)

    assert {:error, :not_found} = ConversationStore.get(internal["id"])
    assert {:ok, _} = ConversationStore.get(internal["id"], access_context: context)
    assert {:error, :not_found} = Handbeam.ConversationTranscriptStore.list(internal["id"])

    assert {:ok, [_]} =
             Handbeam.ConversationTranscriptStore.list(internal["id"], access_context: context)

    state = %{tasks: %{}, viewers: %{}}

    assert {:noreply, ^state} =
             Handbeam.Runtime.TaskTracker.handle_info(
               {:run_lifecycle, internal["id"], :run_start, %{}},
               state
             )

    child_ref = Process.monitor(child)
    send(child, :finish)
    assert {:ok, text, details} = Task.await(task, 5_000)
    assert text =~ "lib/sample.ex:17"
    assert details.usage.input_tokens == 7
    assert_receive {:DOWN, ^child_ref, :process, ^child, _}, 2_000
    assert Registry.lookup(Handbeam.AgentRunRegistry, internal["id"]) == []
    assert %{input_tokens: 0} = elem(ConversationStore.get_token_usage(parent["id"]), 1)

    assert %{details.child_run_id => %{"input_tokens" => 7}} ==
             Map.new(ConversationStore.delegated_usage(parent["id"]), fn {id, usage} ->
               {id, Map.take(usage, ["input_tokens"])}
             end)

    ConversationStore.record_delegated_usage(parent["id"], details.child_run_id, %{
      input_tokens: 99
    })

    assert ConversationStore.delegated_usage(parent["id"])[details.child_run_id]["input_tokens"] ==
             7
  end

  test "shorter deadline stops provider and Runner before returning", %{context: context} do
    task = delegate(%{context | tool_timeout: 4_000})
    assert_receive {:provider, :child, child, _, _, _}, 2_000
    ref = Process.monitor(child)
    assert {:error, _, %{status: :timed_out, usage_complete?: false}} = Task.await(task, 5_000)
    assert_receive {:DOWN, ^ref, :process, ^child, _}, 1_000
  end

  test "parent supervisor teardown does not own child cleanup", %{context: context} do
    task = delegate(context)
    assert_receive {:provider, :child, child, _, _, _}, 2_000
    child_ref = Process.monitor(child)
    parent_ref = Process.monitor(context.runner_pid)
    assert :ok = Coordinator.cancel(context.conversation_id)
    assert_receive {:DOWN, ^parent_ref, :process, _, _}, 2_000
    assert {:error, _, %{status: :parent_closed}} = Task.await(task, 5_000)
    assert_receive {:DOWN, ^child_ref, :process, ^child, _}, 2_000
    assert Process.alive?(Process.whereis(Delegation))
  end

  test "all terminal forms close children but interruption does not", %{context: context} do
    statuses = [:completed, :max_turns, :budget_exceeded, :halted, :error, :cancelled]

    for status <- statuses ++ Enum.map(statuses, &Atom.to_string/1) do
      task = delegate(context)
      assert_receive {:provider, :child, child, _, _, _}, 2_000

      send(
        Delegation,
        {:run_lifecycle, context.conversation_id, :run_end, %{status: :interrupted}}
      )

      assert map_size(:sys.get_state(Delegation).jobs) == 1
      assert Process.alive?(child)
      send(Delegation, {:run_lifecycle, context.conversation_id, :run_end, %{status: status}})
      assert {:error, _, %{status: :parent_closed}} = Task.await(task, 5_000)
    end
  end

  test "child cancellation reconciles tools without exposing its transcript", %{context: context} do
    task = delegate(context)
    assert_receive {:provider, :child, _child, _, _, _}, 2_000
    [{id, job}] = Map.to_list(:sys.get_state(Delegation).jobs)

    assert {:ok, _} =
             Handbeam.ConversationTranscriptStore.append(id, %{
               "id" => "running-tool",
               "content_type" => "tool",
               "tool_status" => "running",
               "run_id" => job.run_id,
               "tool_name" => "read"
             })

    assert {:error, :not_found} =
             Handbeam.ConversationTranscriptStore.list(id,
               runner_pid: job.runner,
               run_id: job.run_id
             )

    assert :ok = Handbeam.Agent.TranscriptRecovery.recover(id)
    assert {:ok, entries} = Handbeam.ConversationStore.load_messages_result(id)
    assert Enum.find(entries, &(&1["id"] == "running-tool"))["tool_status"] == "running"

    assert :ok = Coordinator.cancel(id)
    assert {:error, _, _} = Task.await(task, 5_000)
    assert {:ok, entries} = Handbeam.ConversationTranscriptStore.list(id, access_context: context)
    assert Enum.find(entries, &(&1["id"] == "running-tool"))["tool_status"] == "cancelled"
  end

  test "child crash does not restart or stop its parent", %{context: context} do
    task = delegate(context)
    assert_receive {:provider, :child, child, _, _, _}, 2_000
    [{id, job}] = Map.to_list(:sys.get_state(Delegation).jobs)

    assert {:ok, _} =
             Handbeam.ConversationTranscriptStore.append(id, %{
               "id" => "unfinished-reply",
               "role" => "assistant",
               "status" => "streaming",
               "content" => "durable before crash",
               "run_id" => job.run_id
             })

    send(child, :crash)
    assert {:error, _, _} = Task.await(task, 5_000)
    assert {:ok, entries} = Handbeam.ConversationStore.load_messages_result(id)
    reply = Enum.find(entries, &(&1["id"] == "unfinished-reply"))
    assert reply["status"] == "error"
    assert reply["content"] == "durable before crash"
    assert {:error, :not_found} = Handbeam.ConversationTranscriptStore.list(id)
    assert Policy.live_parent?(context)
    refute_receive {:provider, :child, _, _, _, _}, 100
  end

  test "approval is blocked and cleaned rather than left awaiting a user", %{context: context} do
    path = Handbeam.WorkspaceSettings.path(context.working_directory)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Handbeam.JSON.encode!(%{"tools" => %{"per_tool" => %{"read" => "prompt"}}}))
    task = delegate(context)
    assert_receive {:provider, :child, child, _, _, _}, 2_000
    send(child, :approval)
    assert {:error, _, %{status: :blocked, usage: %{input_tokens: 11}}} = Task.await(task, 5_000)
    assert Policy.live_parent?(context)
  end

  test "killed tool caller cannot orphan a child", %{context: context} do
    owner = Process.whereis(Delegation)
    :erlang.trace(owner, true, [:receive])
    on_exit(fn -> :erlang.trace(owner, false, [:receive]) end)
    task = delegate(context)
    assert_receive {:provider, :child, child, _, _, _}, 2_000
    assert_receive {:trace, ^owner, :receive, {:started, id, _run_id, {:ok, _}}}, 2_000
    ref = Process.monitor(child)
    Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^ref, :process, ^child, _}, 2_000
    assert_receive {:trace, ^owner, :receive, {:cleaned, ^id, _, _}}, 2_000
    # The worker's DOWN precedes usage persistence. Drain the owner callback
    # before teardown removes HOME and races the final ledger write.
    refute Map.has_key?(:sys.get_state(owner).jobs, id)
    assert Policy.live_parent?(context)
  end

  test "startup blocked past deadline cannot start after lost acknowledgement", %{
    context: context
  } do
    :sys.suspend(Handbeam.AgentRunSupervisor)

    try do
      task = delegate(%{context | tool_timeout: 4_000})
      assert {:error, _, %{status: :cleaning_up}} = Task.await(task, 5_000)
    after
      :sys.resume(Handbeam.AgentRunSupervisor)
    end

    refute_receive {:provider, :child, _, _, _, _}, 500
  end

  test "authorization rejects globally registered write and recursive task", %{context: context} do
    Handbeam.Tool.Registry.register(Handbeam.Tool.Builtin.Write)
    Handbeam.Tool.Registry.register(Handbeam.Tool.Builtin.Task)
    config = %{context.delegation_config | allowed_tools: ["read"], delegated?: true}
    state = State.init(config, "read only")

    {:ok, _, blocks} =
      Executor.execute_all_with_details(
        [
          %{
            id: "write",
            name: "write",
            input: %{"file_path" => "forbidden.txt", "content" => "no"}
          },
          %{id: "recursive", name: "task", input: %{"task" => "no", "criteria" => "no"}}
        ],
        state
      )

    assert Enum.all?(blocks, & &1.is_error)
    assert Enum.all?(blocks, &String.contains?(&1.content, "Unknown tool"))
    refute File.exists?(Path.join(context.working_directory, "forbidden.txt"))
  end

  test "native capabilities and custom middleware are not inherited", %{context: context} do
    provider =
      Policy.provider_config(%{
        web_search: true,
        x_search: true,
        previous_response_id: "parent-history",
        use_previous_response_id: true,
        built_in_tools: [%{type: "code_interpreter"}, %{"type" => "web_search_preview"}]
      })

    assert provider.web_search
    refute Map.has_key?(provider, :x_search)
    refute Map.has_key?(provider, :previous_response_id)
    refute provider.use_previous_response_id
    assert provider.built_in_tools == [%{"type" => "web_search_preview"}]
    {:ok, opts} = Policy.child_opts(context, 30_000)
    assert opts[:history_messages] == []
    assert opts[:delivery] == Handbeam.Delivery.Noop
    assert opts[:allowed_tools] == ["read"]

    assert opts[:middleware] == [
             Handbeam.Agent.Middleware.Security,
             Handbeam.Agent.Middleware.ToolGuard
           ]

    assert {:error, reason} =
             Policy.validate(%{
               context
               | delegation_config: %{context.delegation_config | max_budget_cents: 1}
             })

    assert reason =~ "monetary budget"
  end

  test "delegated supervision never restarts either child" do
    assert Handbeam.Agent.RunSupervisor.child_spec(run_opts: [delegated?: true]).restart ==
             :temporary

    assert Handbeam.Agent.RunSupervisor.child_spec(run_opts: []).restart == :permanent

    {:ok, {_, children}} =
      Handbeam.Agent.RunSupervisor.init(conversation_id: "internal", run_opts: [delegated?: true])

    assert Enum.all?(children, &(&1.restart == :temporary))

    {:ok, {_, children}} =
      Handbeam.Agent.RunSupervisor.init(conversation_id: "ordinary", run_opts: [])

    assert Enum.all?(children, &(&1.restart == :transient))
  end
end

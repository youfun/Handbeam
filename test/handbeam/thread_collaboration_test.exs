defmodule Handbeam.ThreadCollaborationTest do
  use ExUnit.Case, async: false
  alias Handbeam.{ConversationStore, ConversationTranscriptStore, Threads}
  alias Handbeam.Threads.Collaboration

  defmodule HoldProvider do
    @behaviour Handbeam.Agent.Provider
    def complete(_messages, _tools, config) do
      send(config.notify, {:held, self(), config})

      receive do
        :release -> :ok
      end

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbeam.Agent.Message.assistant("Audited safely")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{}
       }}
    end

    def stream(messages, tools, config, _chunk), do: complete(messages, tools, config)
  end

  setup do
    home = Path.join(System.tmp_dir!(), "handoffs-#{Ecto.UUID.generate()}")
    File.mkdir_p!(home)
    env = Map.new(~w(HOME HANDBEAM_MODELS_FILE), &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    models = Path.join(home, "models.json")

    File.write!(
      models,
      ~s({"providers":{"fake":{"baseUrl":"http://localhost","api":"openai-chat-completions","apiKey":"fake","models":[{"id":"fake-model","name":"Fake"}]}}})
    )

    System.put_env("HANDBEAM_MODELS_FILE", models)
    {:ok, source} = ConversationStore.create("ws")
    {:ok, target} = ConversationStore.create("ws")

    opts = [
      workspace_path: home,
      model: "fake/fake-model",
      provider: HoldProvider,
      provider_config: %{notify: self()},
      tools: [],
      source: :cli,
      workspace_id: "ws",
      streaming: false
    ]

    context = %{
      conversation_id: source["id"],
      workspace_id: "ws",
      run_id: "source-run",
      thread_run_opts: opts
    }

    on_exit(fn ->
      for m <- ConversationStore.list_metadata("ws"),
          do: Handbeam.Agent.Coordinator.cancel(m["id"])

      for {key, value} <- env,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))

      File.rm_rf!(home)
    end)

    %{source: source["id"], target: target["id"], context: context, opts: opts}
  end

  test "Coordinator sends once, preserves trusted origin, defaults steer and allows explicit follow_up",
       c do
    {:ok, ack} = Handbeam.Agent.Coordinator.add_message(c.target, "Human task", c.opts)
    assert_receive {:held, _, _}, 2000

    assert {:ok, %{state: "running", current_run: run}} =
             Threads.status(%{"thread" => c.target}, c.context)

    assert run == ack.run_id
    :sys.replace_state(ack.run_pid, &%{&1 | status: :awaiting_approval})

    assert {:ok, %{state: "awaiting_approval"}} =
             Threads.status(%{"thread" => c.target}, c.context)

    :sys.replace_state(ack.run_pid, &%{&1 | status: :running})
    input = %{"thread" => c.target, "message" => "Report", "request_id" => "same"}
    tasks = for _ <- 1..4, do: Task.async(fn -> Collaboration.send_message(input, c.context) end)
    receipts = Enum.map(tasks, &Task.await/1)
    assert Enum.all?(receipts, &match?({:ok, %{delivery: "enqueued"}}, &1))
    {:ok, first} = hd(receipts)

    assert {:ok, %{delivery: "enqueued"}} =
             Collaboration.send_message(
               %{input | "request_id" => "later"} |> Map.put("deliver_as", "follow_up"),
               c.context
             )

    {:ok, entries} = ConversationTranscriptStore.list(c.target)
    inbound = Enum.filter(entries, &(get_in(&1, ["origin", "kind"]) == "thread"))
    assert length(inbound) == 2
    assert Enum.map(inbound, & &1["delivery"]) == ["steer", "follow_up"]
    assert hd(inbound)["origin"]["conversation_id"] == c.source
    assert hd(inbound)["origin"]["run_id"] == "source-run"
    assert hd(inbound)["id"] == first.message_id
    assert hd(inbound)["consumption"] == "pending"

    Handbeam.Agent.TranscriptPersistence.handle_event(
      c.target,
      {:candidate_message_injected, %{message_ids: [first.message_id]}},
      []
    )

    {:ok, entries} = ConversationTranscriptStore.list(c.target)
    assert Enum.find(entries, &(&1["id"] == first.message_id))["consumption"] == "consumed"
  end

  test "new delegated runtime is read-only, unbounded and reports final result once", c do
    {:ok, receipt} =
      Collaboration.create(
        %{"title" => "Audit", "message" => "Read only", "request_id" => "audit"},
        c.context
      )

    assert receipt.delivery == "started"
    assert_receive {:held, provider, config}, 2000
    refute Map.has_key?(config, :max_tokens)
    {:ok, status} = Handbeam.Agent.Runner.status(receipt.thread)
    state = :sys.get_state(status.run_pid)
    refute state.opts[:max_turns] == 3
    assert state.opts[:delegated_read_only]

    assert Handbeam.Agent.Config.from_opts(state.opts).context.thread_handoff_id ==
             receipt.handoff_id

    Phoenix.PubSub.subscribe(Handbeam.PubSub, "conversation:updated")
    send(provider, :release)
    assert_receive {:held, _parent_provider, _}, 3000
    {:ok, parent_entries} = ConversationTranscriptStore.list(c.source)
    result = Enum.find(parent_entries, &(get_in(&1, ["origin", "important"]) == true))
    assert result["origin"]["conversation_id"] == receipt.thread
    assert result["origin"]["handoff_id"] == receipt.handoff_id
    assert result["content"] =~ "Task ended (completed)"

    assert {:ok, %{last_result: "completed"}} =
             Threads.status(%{"thread" => receipt.thread}, c.context)

    assert {:ok, child_entries} = ConversationTranscriptStore.list(receipt.thread)
    assert Enum.count(child_entries, &(&1["important"] == true)) == 1
  end

  test "inbound persistence failure is uncertain, retained and never dispatched twice", c do
    path = ConversationStore.messages_path(c.target)
    File.rm!(path)
    File.mkdir!(path)
    input = %{"thread" => c.target, "message" => "Must survive", "request_id" => "fail"}
    assert {:ok, %{delivery: "delivery_unknown"}} = Collaboration.send_message(input, c.context)
    File.rmdir!(path)
    File.write!(path, "")
    assert {:ok, %{delivery: "delivery_unknown"}} = Collaboration.send_message(input, c.context)
    refute_receive {:held, _, _}, 100
    assert {:ok, []} = ConversationTranscriptStore.list(c.target)
  end

  test "independent handoffs, replies and retries preserve their exact association", c do
    {:ok, first} =
      Collaboration.create(
        %{"title" => "Audit", "message" => "ALPHA request", "request_id" => "alpha"},
        c.context
      )

    assert_receive {:held, _, _}, 2000
    input = %{"thread" => first.thread, "message" => "BETA request", "request_id" => "beta"}
    {:ok, second} = Collaboration.send_message(input, c.context)
    assert first.handoff_id != second.handoff_id
    assert {:ok, ^second} = Collaboration.send_message(input, c.context)

    child_context = %{c.context | conversation_id: first.thread}

    for {receipt, label} <- [{first, "ALPHA"}, {second, "BETA"}] do
      reply = %{
        "message" => "#{label} result",
        "request_id" => "#{label}-result",
        "handoff_id" => receipt.handoff_id
      }

      assert {:ok, result} = Collaboration.reply(reply, child_context)
      assert result.handoff_id == receipt.handoff_id
      assert {:ok, ^result} = Collaboration.reply(reply, child_context)
    end

    {:ok, parent_entries} = ConversationTranscriptStore.list(c.source)
    {:ok, child_entries} = ConversationTranscriptStore.list(first.thread)
    assert Enum.count(parent_entries, &(&1["content_type"] == "thread_handoff")) == 2

    for {receipt, label} <- [{first, "ALPHA"}, {second, "BETA"}] do
      [request] =
        Enum.filter(child_entries, &(get_in(&1, ["origin", "handoff_id"]) == receipt.handoff_id))

      assert request["content"] =~ "#{label} request"

      [result] =
        Enum.filter(parent_entries, &(get_in(&1, ["origin", "handoff_id"]) == receipt.handoff_id))

      assert result["content"] =~ "#{label} result"
      assert result["origin"]["important"]
    end

    assert {:error, :invalid_handoff_id} =
             Collaboration.send_message(
               Map.put(input, "request_id", "forged") |> Map.put("handoff_id", "invented"),
               c.context
             )

    assert {:error, :invalid_handoff_id} =
             Collaboration.send_message(
               %{input | "thread" => c.target, "request_id" => "wrong-peer"}
               |> Map.put("handoff_id", first.handoff_id),
               c.context
             )

    assert {:error, :idempotency_conflict} =
             Collaboration.send_message(Map.put(input, "handoff_id", first.handoff_id), c.context)
  end

  test "completion and implicit reply use current handoff, not original child task", c do
    {:ok, first} =
      Collaboration.create(
        %{"title" => "Audit", "message" => "First", "request_id" => "first"},
        c.context
      )

    assert_receive {:held, _, _}, 2000

    {:ok, second} =
      Collaboration.send_message(
        %{"thread" => first.thread, "message" => "Second", "request_id" => "second"},
        c.context
      )

    child_context = %{c.context | conversation_id: first.thread, run_id: "second-run"}
    # A report for a different association in the same run must not suppress this completion.
    {:ok, _} =
      Collaboration.reply(
        %{"message" => "First result", "request_id" => "first-result"},
        child_context
      )

    opts =
      Keyword.merge(c.opts, run_id: "second-run", origin: %{"handoff_id" => second.handoff_id})

    assert {:ok, final} = Collaboration.completed(first.thread, %{status: :completed}, opts)
    assert final.handoff_id == second.handoff_id
    assert :ok = Collaboration.completed(first.thread, %{status: :completed}, opts)

    context = Map.put(child_context, :thread_handoff_id, second.handoff_id)

    assert {:ok, report} =
             Collaboration.reply(
               %{"message" => "Second details", "request_id" => "details"},
               context
             )

    assert report.handoff_id == second.handoff_id
    {:ok, entries} = ConversationTranscriptStore.list(c.source)
    [result] = Enum.filter(entries, &(&1["id"] == final.message_id))
    assert result["origin"]["handoff_id"] == second.handoff_id
    assert result["origin"]["important"]
    assert Threads.project_message(result)["handoff_id"] == second.handoff_id
  end

  test "a mixed run cannot copy another task's assistant text into the terminal report", c do
    {:ok, first} =
      Collaboration.create(
        %{"title" => "Audit", "message" => "ALPHA", "request_id" => "alpha"},
        c.context
      )

    assert_receive {:held, _, _}, 2000
    {:ok, status} = Handbeam.Agent.Runner.status(first.thread)
    opts = :sys.get_state(status.run_pid).opts

    {:ok, second} =
      Collaboration.send_message(
        %{"thread" => first.thread, "message" => "BETA", "request_id" => "beta"},
        c.context
      )

    :ok =
      Handbeam.Agent.TranscriptPersistence.handle_event(
        first.thread,
        {:candidate_message_injected, %{message_ids: [second.message_id]}},
        opts
      )

    {:ok, _} =
      ConversationTranscriptStore.append(first.thread, %{
        "id" => "mixed-output",
        "role" => "assistant",
        "run_id" => opts[:run_id],
        "content" => "ALPHA details and BETA private result"
      })

    assert {:ok, final} = Collaboration.completed(first.thread, %{status: :completed}, opts)
    {:ok, entries} = ConversationTranscriptStore.list(c.source)
    report = Enum.find(entries, &(&1["id"] == final.message_id))
    assert report["origin"]["handoff_id"] == first.handoff_id
    assert report["content"] =~ "no task-specific result inferred"
    refute report["content"] =~ "BETA private result"
  end
end

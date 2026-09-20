defmodule Handbeam.Agent.TranscriptPersistenceTest do
  use ExUnit.Case, async: false

  alias Handbeam.Agent.TranscriptPersistence

  defmodule FailingStore do
    alias Handbeam.ConversationTranscriptStore.ConversationStore, as: Store

    def append(id, entry, opts) do
      if opts[:fail_operation] == :append,
        do: {:error, :enospc},
        else: Store.append(id, entry, opts)
    end

    def update(id, entry_id, patch, opts) do
      if opts[:fail_operation] == :update,
        do: {:error, :eacces},
        else: Store.update(id, entry_id, patch, opts)
    end
  end

  defmodule TestDelivery do
    @behaviour Handbeam.Delivery

    @impl true
    def deliver(entry, opts) do
      send(Keyword.fetch!(opts, :notify), {:delivered, entry})
      :ok
    end
  end

  defmodule ApprovalFinalProvider do
    @behaviour Handbeam.Agent.Provider

    @impl true
    def complete(_messages, _tools, _config) do
      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbeam.Agent.Message.assistant("Approval finished")],
         usage: %{input_tokens: 3, output_tokens: 7}
       }}
    end

    @impl true
    def stream(messages, tools, config, _on_chunk), do: complete(messages, tools, config)
  end

  setup do
    old_home = System.get_env("HOME")

    home_dir =
      Path.join(
        System.tmp_dir!(),
        "sigil_agent_transcript_home_#{System.unique_integer([:positive])}"
      )

    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      if File.exists?(home_dir), do: File.rm_rf!(home_dir)
    end)

    :ok
  end

  test "approval resume finalizes durable assistant and automatically collapses preceding work" do
    alias Handbeam.Agent.{Config, Message, State, Turn}

    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    id = conversation["id"]
    on_event = &TranscriptPersistence.handle_event(id, &1)
    on_event.({:run_start, %{model: "fake"}})
    on_event.({:message_delta, %{chunk: "I will run a command"}})
    on_event.({:tool_start, %{tool_use_id: "approval-1", tool: "bash", input: %{command: "pwd"}}})
    on_event.({:run_end, %{status: :interrupted}})

    state =
      State.init(
        %Config{
          provider: ApprovalFinalProvider,
          model: "fake",
          max_turns: 5,
          provider_config: %{}
        },
        "check"
      )
      |> State.append_messages([
        Message.tool_use([
          %{type: "tool_use", id: "approval-1", name: "bash", input: %{"command" => "pwd"}}
        ])
      ])
      |> Map.merge(%{
        status: :interrupted,
        turn: 1,
        interrupt_data: %{hitl_tool_call_ids: ["approval-1"]}
      })

    result =
      Turn.resume_after_tool_approval(
        state,
        [%{"tool_call_id" => "approval-1", "action" => "deny"}],
        on_event: on_event
      )

    assert result.status == :completed
    entries = Handbeam.ConversationStore.load_messages(id)
    final = Enum.find(entries, &(&1["content"] == "Approval finished"))
    assert final["phase"] == "final"
    assert final["status"] == "completed"
  end

  test "failed append preserves the buffer and does not complete or deliver the reply" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    id = conversation["id"]

    opts = [
      transcript_store: FailingStore,
      delivery: TestDelivery,
      delivery_opts: [notify: self()]
    ]

    :ok = TranscriptPersistence.handle_event(id, {:run_start, %{}}, opts)
    :ok = TranscriptPersistence.handle_event(id, {:message_delta, %{chunk: "first "}}, opts)
    :ok = TranscriptPersistence.handle_event(id, {:message_delta, %{chunk: "second"}}, opts)

    assert_raise RuntimeError, ~r/Assistant transcript persistence failed.*enospc/, fn ->
      TranscriptPersistence.handle_event(
        id,
        {:run_end, %{status: :completed}},
        Keyword.put(opts, :fail_operation, :append)
      )
    end

    assert [] = Handbeam.ConversationStore.load_messages(id)
    refute_received {:delivered, _}

    :ok = TranscriptPersistence.handle_event(id, {:message_delta, %{chunk: " third"}}, opts)
    assert :ok = TranscriptPersistence.handle_event(id, {:run_end, %{status: :completed}}, opts)

    assert [%{"content" => "first second third", "status" => "completed", "phase" => "final"}] =
             Handbeam.ConversationStore.load_messages(id)

    assert_received {:delivered, %{"delivery_delta" => "first second third"}}
    refute_received {:delivered, _}
  end

  test "failed update retains only unsaved deltas and cannot advance the tool boundary" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    id = conversation["id"]

    opts = [
      transcript_store: FailingStore,
      delivery: TestDelivery,
      delivery_opts: [notify: self()]
    ]

    :ok = TranscriptPersistence.handle_event(id, {:run_start, %{}}, opts)
    :ok = TranscriptPersistence.handle_event(id, {:message_delta, %{chunk: "saved"}}, opts)
    :ok = TranscriptPersistence.handle_event(id, {:turn_end, %{}}, opts)
    assert_received {:delivered, %{"delivery_delta" => "saved"}}
    :ok = TranscriptPersistence.handle_event(id, {:message_delta, %{chunk: " pending"}}, opts)
    tool_event = {:tool_start, %{tool: "read", tool_use_id: "read-1", input: %{}}}

    assert_raise RuntimeError, ~r/Assistant transcript persistence failed.*eacces/, fn ->
      TranscriptPersistence.handle_event(
        id,
        tool_event,
        Keyword.put(opts, :fail_operation, :update)
      )
    end

    assert [%{"content" => "saved", "status" => "streaming"}] =
             Handbeam.ConversationStore.load_messages(id)

    refute_received {:delivered, _}
    :ok = TranscriptPersistence.handle_event(id, {:message_delta, %{chunk: " later"}}, opts)
    assert :ok = TranscriptPersistence.handle_event(id, tool_event, opts)

    assert [
             %{"content" => "saved pending later", "phase" => "commentary"},
             %{"id" => "tool-read-1"}
           ] = Handbeam.ConversationStore.load_messages(id)

    assert_received {:delivered, %{"delivery_delta" => " pending later"}}
    refute_received {:delivered, _}
  end

  test "persists assistant deltas without a LiveView process" do
    {:ok, conversation} =
      Handbeam.ConversationStore.create("default",
        timeline: [
          %{
            "id" => "msg-user-1",
            "content_type" => "user_msg",
            "role" => "user",
            "content" => "hello"
          }
        ]
      )

    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "assistant "}}
    )

    TranscriptPersistence.handle_event(conversation_id, {:message_delta, %{chunk: "reply"}})
    TranscriptPersistence.handle_event(conversation_id, {:run_end, %{status: "completed"}})

    messages = Handbeam.ConversationStore.load_messages(conversation_id)

    assert Enum.any?(messages, &match?(%{"role" => "user", "content" => "hello"}, &1))

    assert Enum.any?(
             messages,
             &match?(%{"role" => "assistant", "content" => "assistant reply"}, &1)
           )
  end

  test "buffers message_delta without immediate persistence" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "delayed write"}}
    )

    messages = Handbeam.ConversationStore.load_messages(conversation_id)

    # Should NOT be in transcript yet — only buffered in Process dict
    refute Enum.any?(
             messages,
             &match?(%{"role" => "assistant", "content" => "delayed write"}, &1)
           )
  end

  test "flushes buffered text at run_end boundary" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "first "}}
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "second"}}
    )

    # Before boundary: nothing persisted
    messages_before = Handbeam.ConversationStore.load_messages(conversation_id)

    refute Enum.any?(
             messages_before,
             &match?(%{"role" => "assistant"}, &1)
           )

    # run_end triggers flush
    TranscriptPersistence.handle_event(conversation_id, {:run_end, %{status: "completed"}})

    messages_after = Handbeam.ConversationStore.load_messages(conversation_id)

    assert Enum.any?(
             messages_after,
             &match?(%{"role" => "assistant", "content" => "first second"}, &1)
           )
  end

  test "flushes buffered text at tool_start boundary" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "assistant text"}}
    )

    # tool_start triggers flush of pending assistant text
    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "tu_1", tool: "bash", input: %{}}}
    )

    messages = Handbeam.ConversationStore.load_messages(conversation_id)

    assert Enum.any?(
             messages,
             &match?(%{"role" => "assistant", "content" => "assistant text"}, &1)
           )
  end

  test "thinking_delta does not trigger transcript flush" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    # Buffer some text
    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "keep buffered"}}
    )

    # Send a thinking_delta — should NOT flush the buffer
    TranscriptPersistence.handle_event(
      conversation_id,
      {:thinking_delta, %{chunk: "thinking text"}}
    )

    messages = Handbeam.ConversationStore.load_messages(conversation_id)

    # Assistant text should still be buffered, not written
    refute Enum.any?(
             messages,
             &match?(%{"role" => "assistant", "content" => "keep buffered"}, &1)
           )
  end

  test "thinking_delta raw string variant does not trigger flush" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "unflushed"}}
    )

    # Anthropic-style thinking_delta (raw string, not map)
    TranscriptPersistence.handle_event(
      conversation_id,
      {:thinking_delta, "raw thinking string"}
    )

    messages = Handbeam.ConversationStore.load_messages(conversation_id)

    refute Enum.any?(
             messages,
             &match?(%{"role" => "assistant", "content" => "unflushed"}, &1)
           )
  end

  test "does not persist provider thinking wrappers as assistant text" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "Before "}}
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "<think>hidden</think><think>reasoning</think>"}}
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: " after"}}
    )

    TranscriptPersistence.handle_event(conversation_id, {:run_end, %{status: "completed"}})

    messages = Handbeam.ConversationStore.load_messages(conversation_id)
    assistant = Enum.find(messages, &(&1["role"] == "assistant"))

    assert assistant["content"] == "Before  after"
    refute assistant["content"] =~ "<think>"
    refute assistant["content"] =~ "hidden"
    refute assistant["content"] =~ "reasoning"
  end

  test "persists tool start and end as internal transcript records" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "toolu_1", tool: "read", input: %{file_path: "a.txt"}}}
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_end, %{tool_use_id: "toolu_1", tool: "read", duration_ms: 12}}
    )

    messages = Handbeam.ConversationStore.load_messages(conversation_id)

    assert %{
             "id" => "tool-toolu_1",
             "message_type" => "tool",
             "direction" => "internal",
             "tool_status" => "done"
           } = Enum.find(messages, &(&1["id"] == "tool-toolu_1"))
  end

  test "redacts sensitive tool inputs before writing durable history" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])

    TranscriptPersistence.handle_event(
      conversation["id"],
      {:tool_start,
       %{
         tool_use_id: "secret-input",
         tool: "git",
         input: %{
           "action" => "push",
           "password" => "fixture-secret",
           "nested" => %{token: "nested-secret"}
         }
       }}
    )

    [entry] = Handbeam.ConversationStore.load_messages(conversation["id"])
    assert entry["input"]["action"] == "push"
    assert entry["input"]["password"] == "[REDACTED]"
    assert entry["input"]["nested"]["token"] == "[REDACTED]"
  end

  test "marks assistant message as completed on run_end" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:message_delta, %{chunk: "hello world"}}
    )

    TranscriptPersistence.handle_event(conversation_id, {:run_end, %{status: "completed"}})

    messages = Handbeam.ConversationStore.load_messages(conversation_id)
    assistant = Enum.find(messages, &(&1["role"] == "assistant"))

    assert assistant, "expected an assistant message in the transcript"

    assert assistant["status"] == "completed",
           "expected assistant status to be 'completed', got: #{inspect(assistant["status"])}"
  end

  test "append_inbound records delivery and interrupts_work from deliver_as" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    assert {:ok, new_run} =
             TranscriptPersistence.append_inbound(conversation_id, "start",
               source: :cli,
               deliver_as: :new_run
             )

    assert {:ok, steer} =
             TranscriptPersistence.append_inbound(conversation_id, "steer me",
               source: :cli,
               deliver_as: :steer
             )

    assert {:ok, follow_up} =
             TranscriptPersistence.append_inbound(conversation_id, "later",
               source: :cli,
               deliver_as: :follow_up
             )

    assert {:ok, default_idle} =
             TranscriptPersistence.append_inbound(conversation_id, "no deliver_as", source: :cli)

    assert new_run["delivery"] == "new_run"
    assert new_run["interrupts_work"] == false
    assert steer["delivery"] == "steer"
    assert steer["interrupts_work"] == true
    assert follow_up["delivery"] == "follow_up"
    assert follow_up["interrupts_work"] == false
    assert default_idle["delivery"] == "new_run"
    assert default_idle["interrupts_work"] == false

    persisted = Handbeam.ConversationStore.load_messages(conversation_id)

    assert Enum.map(persisted, &{&1["content"], &1["delivery"], &1["interrupts_work"]}) == [
             {"start", "new_run", false},
             {"steer me", "steer", true},
             {"later", "follow_up", false},
             {"no deliver_as", "new_run", false}
           ]
  end

  test "history reconstruction drops delivery metadata from provider messages" do
    entry = %{
      "role" => "user",
      "content" => "hello",
      "delivery" => "steer",
      "interrupts_work" => true,
      "metadata" => %{"source" => "cli", "delivery" => "steer"}
    }

    assert [%Handbeam.Agent.Message{role: :user, content: "hello"} = message] =
             Handbeam.Attachments.History.to_messages(entry, nil, "conv-delivery")

    refute Map.has_key?(Map.from_struct(message), :delivery)
    refute Map.has_key?(Map.from_struct(message), :interrupts_work)
    refute Map.has_key?(Map.from_struct(message), :metadata)
  end

  test "marks unfinished tools as error on run_end with error" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}})

    # Start a tool but never send tool_end (simulating a crash)
    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "toolu_crash", tool: "bash", input: %{command: "bad"}}}
    )

    # run_end with error (simulating crash before tool_end)
    TranscriptPersistence.handle_event(
      conversation_id,
      {:run_end, %{status: "error", error: "nxdomain"}}
    )

    messages = Handbeam.ConversationStore.load_messages(conversation_id)
    tool = Enum.find(messages, &(&1["id"] == "tool-toolu_crash"))

    assert tool, "expected the tool entry in the transcript"

    assert tool["tool_status"] == "error",
           "expected tool_status to be error, got: #{inspect(tool["tool_status"])}"
  end

  test "run_end cancelled scans durable running tools without process-local tracking" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    run_id = "run-cancel-#{System.unique_integer([:positive])}"
    opts = [run_id: run_id]

    task =
      Task.async(fn ->
        TranscriptPersistence.handle_event(
          conversation_id,
          {:run_start, %{model: "test"}},
          opts
        )

        TranscriptPersistence.handle_event(
          conversation_id,
          {:tool_start,
           %{tool_use_id: "toolu_hold", tool: "bash", input: %{command: "sleep 30"}}},
          opts
        )
      end)

    Task.await(task)

    refute Process.get({Handbeam.Agent.TranscriptPersistence, :running_tools, conversation_id})

    TranscriptPersistence.handle_event(
      conversation_id,
      {:run_end, %{status: "cancelled", turns: 0}},
      opts
    )

    tool =
      Enum.find(
        Handbeam.ConversationStore.load_messages(conversation_id),
        &(&1["id"] == "tool-toolu_hold")
      )

    assert tool["status"] == "cancelled"
    assert tool["tool_status"] == "cancelled"
  end

  test "run_end cancelled only patches the same run and keeps terminal tool statuses" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    opts_a = [run_id: "run-a"]
    opts_b = [run_id: "run-b"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}}, opts_a)

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "a-running", tool: "bash", input: %{command: "hold"}}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "a-done", tool: "read", input: %{path: "a.txt"}}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_end, %{tool_use_id: "a-done", tool: "read", output: "ok"}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "a-error", tool: "bash", input: %{command: "bad"}}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_end, %{tool_use_id: "a-error", tool: "bash", error: "failed"}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "a-cancelled", tool: "bash", input: %{command: "x"}}},
      opts_a
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_end, %{tool_use_id: "a-cancelled", tool: "bash", status: :cancelled}},
      opts_a
    )

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}}, opts_b)

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "b-running", tool: "bash", input: %{command: "other"}}},
      opts_b
    )

    TranscriptPersistence.handle_event(
      conversation_id,
      {:run_end, %{status: :cancelled, turns: 0}},
      opts_a
    )

    messages = Handbeam.ConversationStore.load_messages(conversation_id)
    by_id = Map.new(messages, &{&1["id"], &1})

    assert by_id["tool-a-running"]["status"] == "cancelled"
    assert by_id["tool-a-running"]["tool_status"] == "cancelled"
    assert by_id["tool-a-done"]["status"] == "done"
    assert by_id["tool-a-error"]["status"] == "error"
    assert by_id["tool-a-cancelled"]["status"] == "cancelled"
    assert by_id["tool-b-running"]["status"] == "running"
    assert by_id["tool-b-running"]["tool_status"] == "running"
  end

  test "run_end interrupted does not cancel running tools" do
    {:ok, conversation} = Handbeam.ConversationStore.create("default", timeline: [])
    conversation_id = conversation["id"]
    opts = [run_id: "run-interrupt"]

    TranscriptPersistence.handle_event(conversation_id, {:run_start, %{model: "test"}}, opts)

    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start, %{tool_use_id: "approval-running", tool: "bash", input: %{command: "pwd"}}},
      opts
    )

    TranscriptPersistence.handle_event(conversation_id, {:run_end, %{status: :interrupted}}, opts)

    tool =
      Enum.find(
        Handbeam.ConversationStore.load_messages(conversation_id),
        &(&1["id"] == "tool-approval-running")
      )

    assert tool["status"] == "running"
    assert tool["tool_status"] == "running"
  end
end

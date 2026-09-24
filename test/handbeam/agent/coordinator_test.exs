defmodule Handbeam.Agent.CoordinatorTest do
  use ExUnit.Case, async: false

  alias Handbeam.Agent.Coordinator
  alias Handbeam.PubSub.Session

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Handbeam.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Handbeam.Repo, {:shared, self()})

    old_home = System.get_env("HOME")

    home_dir = Path.join(System.tmp_dir!(), "sigil_coord_home_#{Ecto.UUID.generate()}")

    File.mkdir_p!(home_dir)
    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      File.rm_rf!(home_dir)
    end)

    :ok
  end

  defmodule CrashProvider do
    @behaviour Handbeam.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, _config) do
      raise "intentional provider crash"
    end

    @impl true
    def stream(_messages, _tool_defs, _config, _on_chunk) do
      raise "intentional provider crash"
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

  defmodule HoldProvider do
    @behaviour Handbeam.Agent.Provider

    @impl true
    def complete(_messages, _tool_defs, config) do
      send(Map.fetch!(config, :notify), {:held, self()})

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbeam.Agent.Message.assistant("ok")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{id: "hold-provider", model: "fake-model"}
       }}
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defmodule NotifyProvider do
    @behaviour Handbeam.Agent.Provider

    @impl true
    def complete(messages, _tool_defs, config) do
      send(Map.fetch!(config, :notify), {:provider_messages, messages})

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Handbeam.Agent.Message.assistant("ok")],
         usage: %{input_tokens: 1, output_tokens: 1},
         response_metadata: %{id: "notify-provider", model: "fake-model"}
       }}
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  defp tmp_no_policy_workspace do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sigil_coord_nopolicy_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(dir)

    old = System.get_env("HANDBEAM_MODELS_FILE")
    models_path = Path.join(dir, "models.json")

    File.write!(
      models_path,
      ~s({"providers": {"fake": {"baseUrl": "http://localhost", "api": "openai-chat-completions", "apiKey": "sk-fake", "models": [{"id": "fake-model", "name": "Fake Model"}]}}})
    )

    System.put_env("HANDBEAM_MODELS_FILE", models_path)

    on_exit(fn ->
      if old,
        do: System.put_env("HANDBEAM_MODELS_FILE", old),
        else: System.delete_env("HANDBEAM_MODELS_FILE")

      File.rm_rf(dir)
    end)

    dir
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        workspace_path: tmp_no_policy_workspace(),
        model: "fake/fake-model",
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

  test "inbound write failure rejects both idle entry points before starting a run" do
    for entry_point <- [:add_message, :start_run] do
      sid = "coord-write-failure-#{entry_point}-#{System.unique_integer([:positive])}"
      {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)

      messages_path =
        Path.join([
          System.get_env("HOME"),
          ".handbeam",
          "conversations",
          "items",
          sid,
          "messages.jsonl"
        ])

      File.rm!(messages_path)
      File.mkdir!(messages_path)

      assert {:error, :eisdir} = apply(Coordinator, entry_point, [sid, "not accepted", opts()])
      assert {:error, :not_found} = Handbeam.Agent.Runner.status(sid)
      assert %{meta: %{running?: false}, events: []} = Session.snapshot(sid)
    end
  end

  test "inbound write failure leaves running queues unchanged" do
    sid = "coord-queue-write-failure-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    queue = start_supervised!({Handbeam.Agent.CandidateQueue, session_id: sid, owner: self()})
    :ok = Session.attach_run(sid, self(), queue)

    messages_path =
      Path.join([
        System.get_env("HOME"),
        ".handbeam",
        "conversations",
        "items",
        sid,
        "messages.jsonl"
      ])

    File.rm!(messages_path)
    File.mkdir!(messages_path)

    for delivery <- [:steer, :follow_up] do
      assert {:error, :eisdir} =
               Coordinator.add_message(sid, "not queued", opts(deliver_as: delivery))
    end

    assert [] = Handbeam.Agent.CandidateQueue.get_messages(queue)
    assert %{events: []} = Session.snapshot(sid)
  end

  test "deleting a pending message preserves the other transcript entries" do
    sid = "coord-delete-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    queue = start_supervised!({Handbeam.Agent.CandidateQueue, session_id: sid, owner: self()})
    :ok = Session.attach_run(sid, self(), queue)

    assert {:ok, _} = Coordinator.add_message(sid, "remove", opts(message_id: "pending-delete"))
    assert {:ok, _} = Coordinator.add_message(sid, "keep", opts(message_id: "pending-keep"))

    assert {:ok, saved} =
             Handbeam.ConversationTranscriptStore.append(sid, %{
               "id" => "reply",
               "content" => "working"
             })

    assert :ok = Coordinator.delete_pending_message(sid, "pending-delete")
    assert [%{message: %{id: "pending-keep"}}] = Handbeam.Agent.CandidateQueue.get_messages(queue)
    assert {:ok, [kept, ^saved]} = Handbeam.ConversationTranscriptStore.list(sid)
    assert kept["id"] == "pending-keep"
    assert {:error, :not_found} = Coordinator.delete_pending_message(sid, "pending-delete")
  end

  test "add_message starts a supervised run when session is idle" do
    sid = "coord-idle-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started, run_pid: pid}} =
             Coordinator.add_message(sid, "hello", opts())

    assert is_pid(pid)
    assert inbound_user(sid)["delivery"] == "new_run"
    assert inbound_user(sid)["interrupts_work"] == false
    assert_receive_run_end(sid)
  end

  test "idle add_message writes new_run even when deliver_as is explicit follow_up or steer" do
    sid = "coord-idle-follow-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid, "queued wording", opts(deliver_as: :follow_up))

    assert %{
             "content" => "queued wording",
             "delivery" => "new_run",
             "interrupts_work" => false
           } = inbound_user(sid)

    assert_receive_run_end(sid)

    sid2 = "coord-idle-steer-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid2)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(sid2, "steer wording", opts(deliver_as: :steer))

    assert %{
             "content" => "steer wording",
             "delivery" => "new_run",
             "interrupts_work" => false
           } = inbound_user(sid2)

    assert_receive_run_end(sid2)
  end

  test "add_message enqueues candidate when session is running" do
    sid = "coord-running-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    assert {:ok, %{action: :enqueued, run_pid: nil}} =
             Coordinator.add_message(sid, "steer this", opts())

    assert [%Handbeam.Agent.Message{role: :user, content: "steer this"}] =
             Handbeam.Agent.CandidateQueue.drain_steer(queue)

    assert %{
             "content" => "steer this",
             "delivery" => "steer",
             "interrupts_work" => true
           } = inbound_user(sid)
  end

  test "add_message enqueues to follow_up queue when running with explicit deliver_as" do
    sid = "coord-running-follow-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    assert {:ok, %{action: :enqueued, run_pid: nil}} =
             Coordinator.add_message(sid, "follow up task", opts(deliver_as: :follow_up))

    # Message must land in follow_up queue, NOT steer queue
    assert [%Handbeam.Agent.Message{role: :user, content: "follow up task"}] =
             Handbeam.Agent.CandidateQueue.drain_follow_up(queue)

    assert [] = Handbeam.Agent.CandidateQueue.drain_steer(queue)

    assert %{
             "content" => "follow up task",
             "delivery" => "follow_up",
             "interrupts_work" => false
           } = inbound_user(sid)
  end

  test "add_message enqueues to steer queue when running with explicit deliver_as steer" do
    sid = "coord-running-steer-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    assert {:ok, %{action: :enqueued, run_pid: nil}} =
             Coordinator.add_message(sid, "steer correction", opts(deliver_as: :steer))

    assert [%Handbeam.Agent.Message{role: :user, content: "steer correction"}] =
             Handbeam.Agent.CandidateQueue.drain_steer(queue)

    assert [] = Handbeam.Agent.CandidateQueue.drain_follow_up(queue)

    assert %{
             "content" => "steer correction",
             "delivery" => "steer",
             "interrupts_work" => true
           } = inbound_user(sid)
  end

  test "stamps one id onto Message, transcript, and candidate queue" do
    sid = "coord-id-align-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    id = "msg-shared-#{System.unique_integer([:positive])}"
    message = %Handbeam.Agent.Message{role: :user, content: "aligned", id: nil}

    assert {:ok, %{action: :enqueued}} =
             Coordinator.add_message(
               sid,
               message,
               opts(inbound_id: id, transcript_id: id, message_id: id)
             )

    assert [%Handbeam.Agent.Message{id: ^id, content: "aligned"}] =
             Handbeam.Agent.CandidateQueue.drain_steer(queue)

    assert inbound_user(sid)["id"] == id
    assert inbound_user(sid)["inbound_id"] == id
  end

  test "generates one queue id for a string message with no ids" do
    sid = "coord-noid-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    assert {:ok, %{action: :enqueued}} = Coordinator.add_message(sid, "sns plain", opts())

    assert [%Handbeam.Agent.Message{id: generated, content: "sns plain"}] =
             Handbeam.Agent.CandidateQueue.drain_steer(queue)

    assert is_binary(generated) and generated != "" and generated != "msg-user-unknown"
    assert inbound_user(sid)["id"] == generated
    assert inbound_user(sid)["inbound_id"] == generated
  end

  test "opts message_id wins over Message.id and transcript_id; inbound_id stays independent" do
    sid = "coord-id-conflict-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    message = %Handbeam.Agent.Message{role: :user, content: "conflict", id: "struct-id"}

    assert {:ok, %{action: :enqueued}} =
             Coordinator.add_message(
               sid,
               message,
               opts(message_id: "opt-id", transcript_id: "tr-id", inbound_id: "ack-id")
             )

    assert [%Handbeam.Agent.Message{id: "opt-id", content: "conflict"}] =
             Handbeam.Agent.CandidateQueue.drain_steer(queue)

    assert inbound_user(sid)["id"] == "opt-id"
    assert inbound_user(sid)["inbound_id"] == "ack-id"
  end

  test "SNS entry with explicit deliver_as is not overridden to steer" do
    old_home = System.get_env("HOME")

    home_dir =
      Path.join(System.tmp_dir!(), "sigil_coord_sns_follow_#{System.unique_integer([:positive])}")

    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      if File.exists?(home_dir), do: File.rm_rf!(home_dir)
    end)

    sid = "coord-sns-follow-#{System.unique_integer([:positive])}"
    {:ok, _conversation} = Handbeam.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    assert {:ok, %{action: :enqueued, run_pid: nil}} =
             Coordinator.add_message(
               sid,
               "sns follow message",
               opts(
                 source: :sns,
                 channel: :sns,
                 deliver_as: :follow_up,
                 delivery: TestDelivery,
                 delivery_opts: [notify: self()]
               )
             )

    # Must land in follow_up, not steer — Coordinator must not overwrite deliver_as
    assert [%Handbeam.Agent.Message{role: :user, content: "sns follow message"}] =
             Handbeam.Agent.CandidateQueue.drain_follow_up(queue)

    assert [] = Handbeam.Agent.CandidateQueue.drain_steer(queue)

    assert %{
             "content" => "sns follow message",
             "delivery" => "follow_up",
             "interrupts_work" => false,
             "channel" => "sns"
           } = inbound_user(sid)
  end

  test "SNS running without deliver_as defaults to steer" do
    sid = "coord-sns-steer-default-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    assert {:ok, %{action: :enqueued}} =
             Coordinator.add_message(
               sid,
               "sns steer default",
               opts(source: :sns, channel: :sns)
             )

    assert [%Handbeam.Agent.Message{content: "sns steer default"}] =
             Handbeam.Agent.CandidateQueue.drain_steer(queue)

    assert %{
             "delivery" => "steer",
             "interrupts_work" => true,
             "channel" => "sns"
           } = inbound_user(sid)
  end

  test "task_instructions while running is rejected and never enqueued" do
    sid = "coord-review-running-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)
    {:ok, _session} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: self())
    :ok = Session.attach_run(sid, self(), queue)

    assert {:error, :run_in_progress} =
             Coordinator.add_message(
               sid,
               "write a review",
               opts(task_instructions: "trusted skill body")
             )

    assert Handbeam.Agent.CandidateQueue.get_messages(queue) == []
    refute inbound_user(sid)
  end

  test "concurrent task_instructions cannot silently enqueue on a racing run" do
    sid = "coord-review-race-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)
    :ok = Session.subscribe(sid)
    parent = self()

    hold_opts =
      opts(
        provider: HoldProvider,
        provider_config: %{notify: parent},
        streaming: false
      )

    tasks =
      Enum.map(["first review", "second review"], fn content ->
        Task.async(fn ->
          Coordinator.add_message(
            sid,
            content,
            Keyword.put(hold_opts, :task_instructions, content)
          )
        end)
      end)

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.any?(results, &match?({:ok, %{action: :started}}, &1))
    assert Enum.any?(results, &match?({:error, :run_in_progress}, &1))
    refute Enum.any?(results, &match?({:ok, %{action: :enqueued}}, &1))

    receive do
      {:held, pid} -> send(pid, :release)
    after
      5_000 -> flunk("hold provider never started")
    end

    contents =
      case Handbeam.ConversationTranscriptStore.list(sid) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&(&1["role"] == "user"))
          |> Enum.map(& &1["content"])

        {:error, _} ->
          []
      end

    assert length(contents) == 1
    assert hd(contents) in ["first review", "second review"]
    refute Enum.any?(contents, &(&1 && String.contains?(&1, "task_instructions")))
    assert_receive {:agent_event, %{kind: :run_end}}, 1_000
  end

  test "add_message returns no_active_run when idle and require_running? is true" do
    sid = "coord-require-#{System.unique_integer([:positive])}"

    assert {:error, :no_active_run} =
             Coordinator.add_message(sid, "steer with no run", opts(require_running?: true))
  end

  test "new runs include durable transcript history before the new prompt" do
    sid = "coord-history-#{System.unique_integer([:positive])}"

    assert {:ok, _conversation} = Handbeam.ConversationStore.create("default", id: sid)

    assert {:ok, _} =
             Handbeam.ConversationTranscriptStore.append(sid, %{
               "id" => "old-user",
               "role" => "user",
               "content" => "Earlier user context",
               "delivery" => "steer",
               "interrupts_work" => true,
               "metadata" => %{"source" => "cli", "delivery" => "steer"}
             })

    assert {:ok, _} =
             Handbeam.ConversationTranscriptStore.append(sid, %{
               "id" => "old-assistant",
               "role" => "assistant",
               "content" => "Earlier assistant answer"
             })

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "New prompt",
               opts(provider: NotifyProvider, provider_config: %{notify: self()})
             )

    assert_receive {:provider_messages, messages}

    assert Enum.map(messages, &{&1.role, &1.content}) == [
             {:user, "Earlier user context"},
             {:assistant, "Earlier assistant answer"},
             {:user, "New prompt"}
           ]

    Enum.each(messages, fn message ->
      assert %Handbeam.Agent.Message{} = message
      refute Map.has_key?(Map.from_struct(message), :delivery)
      refute Map.has_key?(Map.from_struct(message), :interrupts_work)
      refute Map.has_key?(Map.from_struct(message), :metadata)
    end)

    assert_receive_run_end(sid)
  end

  test "removed observational memory model does not block an unrestricted workspace" do
    sid = "coord-stale-om-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(
                 om: %{
                   enabled: true,
                   observer_model: "xai/grok-4.7",
                   reflector_model: "xai/grok-4.7"
                 }
               )
             )

    assert_receive_run_end(sid)
  end

  test "allowlisted workspace still rejects a catalog observational memory model" do
    sid = "coord-restricted-om-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)
    # The helper writes models.json inside the workspace and points
    # HANDBEAM_MODELS_FILE at it. Policy must live in a different directory,
    # otherwise saving the catalog overwrites the allowlist.
    _catalog_dir = tmp_no_policy_workspace()
    models_path = System.fetch_env!("HANDBEAM_MODELS_FILE")

    workspace =
      Path.join(System.tmp_dir!(), "sigil_coord_allow_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    File.write!(
      models_path,
      ~s({"providers":{"fake":{"baseUrl":"http://localhost","api":"openai-chat-completions","apiKey":"sk-fake","models":[{"id":"fake-model","name":"Fake Model"}]},"other":{"baseUrl":"http://localhost","api":"openai-chat-completions","apiKey":"sk-other","models":[{"id":"other-model","name":"Other Model"}]}}})
    )

    File.mkdir_p!(Path.dirname(Handbeam.WorkspaceSettings.path(workspace)))

    File.write!(
      Handbeam.WorkspaceSettings.path(workspace),
      ~s({"models":{"allow":{"providers":{"fake":{"models":["fake-model"]}}}}})
    )

    assert {:error, reason} =
             Coordinator.add_message(
               sid,
               "hello",
               opts(
                 workspace_path: workspace,
                 om: %{enabled: true, observer_model: "other/other-model"}
               )
             )

    assert reason =~ "other/other-model"
    refute reason =~ "not in the global catalog"
  end

  test "missing required opts return structured error" do
    sid = "coord-missing-#{System.unique_integer([:positive])}"

    assert {:error, {:missing_opts, missing}} = Coordinator.add_message(sid, "hello", [])
    assert :workspace_path in missing
    assert :model in missing
    assert :provider_config in missing
    assert :tools in missing
    assert :source in missing
  end

  test "task crash is isolated from caller and broadcasts error run_end" do
    sid = "coord-crash-#{System.unique_integer([:positive])}"
    {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)

    assert {:ok, %{action: :started, run_pid: pid}} =
             Coordinator.add_message(sid, "boom", opts(provider: CrashProvider))

    assert is_pid(pid)

    assert_receive_run_end(sid)

    %{events: events} = Session.snapshot(sid)
    assert Enum.any?(events, &match?(%{kind: :run_end, payload: %{status: "error"}}, &1))
  end

  test "SNS-like source persists inbound transcript and delivers assistant outbound" do
    old_home = System.get_env("HOME")

    home_dir =
      Path.join(System.tmp_dir!(), "sigil_coord_sns_home_#{System.unique_integer([:positive])}")

    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      if File.exists?(home_dir), do: File.rm_rf!(home_dir)
    end)

    {:ok, conversation} = Handbeam.ConversationStore.create("default", id: "coord-sns")
    sid = conversation["id"]

    assert {:ok, %{action: :started, run_id: run_id}} =
             Coordinator.add_message(
               sid,
               "hello from sns",
               opts(
                 source: :sns,
                 channel: :sns,
                 delivery: TestDelivery,
                 delivery_opts: [notify: self()],
                 provider: Handbeam.TestSupport.FakeProvider,
                 provider_config: %{scenario: :simple_answer},
                 streaming: false
               )
             )

    assert is_binary(run_id)
    assert_receive {:delivered, %{"role" => "assistant", "delivery_delta" => delivered_delta}}
    assert delivered_delta =~ "Hello!"
    assert_receive_run_end(sid)

    messages = Handbeam.ConversationStore.load_messages(sid)

    assert %{
             "role" => "user",
             "direction" => "inbound",
             "channel" => "sns",
             "content" => "hello from sns",
             "delivery" => "new_run",
             "interrupts_work" => false
           } = Enum.find(messages, &(&1["role"] == "user"))

    assert %{
             "role" => "assistant",
             "direction" => "outbound",
             "channel" => "sns",
             "content" => content
           } = Enum.find(messages, &(&1["role"] == "assistant"))

    assert content =~ "Hello!"
  end

  defp inbound_user(sid) do
    sid
    |> Handbeam.ConversationStore.load_messages()
    |> Enum.find(&(&1["role"] == "user"))
  end

  defp assert_receive_run_end(sid) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    wait_for_run_end(sid, deadline)
  end

  defp wait_for_run_end(sid, deadline) do
    %{events: events} = Session.snapshot(sid)

    if Enum.any?(events, &match?(%{kind: :run_end}, &1)) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("expected run_end event for #{sid}")
      else
        Process.sleep(10)
        wait_for_run_end(sid, deadline)
      end
    end
  end

  # ── Workspace model policy enforcement ──

  describe "workspace model policy enforcement" do
    setup do
      old_models_file = System.get_env("HANDBEAM_MODELS_FILE")

      tmp_dir =
        Path.join(System.tmp_dir!(), "sigil_coord_policy_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      # Write a global config with two providers / two models each
      File.write!(
        Path.join(tmp_dir, "models.json"),
        Jason.encode!(%{
          "defaultProvider" => "cloud-provider",
          "defaultModel" => "cloud-model-v1",
          "providers" => %{
            "cloud-provider" => %{
              "baseUrl" => "https://cloud.example.com/v1",
              "api" => "openai-chat-completions",
              "apiKey" => "sk-cloud",
              "models" => [
                %{"id" => "cloud-model-v1", "name" => "Cloud Model V1"},
                %{"id" => "cloud-model-v2", "name" => "Cloud Model V2"}
              ]
            },
            "local-llm" => %{
              "baseUrl" => "http://localhost:11434/v1",
              "api" => "openai-chat-completions",
              "apiKey" => "sk-local",
              "models" => [
                %{"id" => "qwen2.5-coder:7b", "name" => "Qwen 2.5 Coder 7B"}
              ]
            }
          }
        })
      )

      System.put_env("HANDBEAM_MODELS_FILE", Path.join(tmp_dir, "models.json"))

      on_exit(fn ->
        if old_models_file,
          do: System.put_env("HANDBEAM_MODELS_FILE", old_models_file),
          else: System.delete_env("HANDBEAM_MODELS_FILE")

        File.rm_rf(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir}
    end

    defp write_workspace_policy(workspace_root, policy) do
      settings_dir = Path.join(workspace_root, ".handbeam")
      File.mkdir_p!(settings_dir)
      settings_path = Handbeam.WorkspaceSettings.path(workspace_root)
      File.write!(settings_path, Jason.encode!(%{"models" => policy}))
      settings_path
    end

    defp restricted_opts(workspace_root, extra \\ []) do
      Keyword.merge(
        [
          workspace_path: workspace_root,
          model: "local-llm/qwen2.5-coder:7b",
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

    test "add_message rejects disallowed model for restrictive workspace policy" do
      ws =
        Path.join(
          System.tmp_dir!(),
          "sigil_coord_policy_restricted_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(ws)

      write_workspace_policy(ws, %{
        "allow" => %{
          "providers" => %{
            "local-llm" => %{"models" => ["qwen2.5-coder:7b"]}
          }
        }
      })

      sid = "coord-policy-reject-#{System.unique_integer([:positive])}"

      # cloud-model-v1 is NOT in the allowlist
      assert {:error, reason} =
               Coordinator.add_message(
                 sid,
                 "hello",
                 restricted_opts(ws, model: "cloud-provider/cloud-model-v1")
               )

      assert reason =~ "not allowed"
    end

    test "add_message accepts allowed model for restrictive workspace policy" do
      ws =
        Path.join(
          System.tmp_dir!(),
          "sigil_coord_policy_allow_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(ws)

      write_workspace_policy(ws, %{
        "allow" => %{
          "providers" => %{
            "local-llm" => %{"models" => ["qwen2.5-coder:7b"]}
          }
        }
      })

      sid = "coord-policy-allow-#{System.unique_integer([:positive])}"
      {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)

      assert {:ok, %{action: :started}} =
               Coordinator.add_message(sid, "hello", restricted_opts(ws))

      assert_receive_run_end(sid)
    end

    test "add_message accepts any model when workspace has no policy file" do
      ws =
        Path.join(
          System.tmp_dir!(),
          "sigil_coord_policy_none_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(ws)

      sid = "coord-policy-none-#{System.unique_integer([:positive])}"
      {:ok, _} = Handbeam.ConversationStore.create("default", id: sid)

      assert {:ok, %{action: :started}} =
               Coordinator.add_message(
                 sid,
                 "hello",
                 restricted_opts(ws, model: "cloud-provider/cloud-model-v2")
               )

      assert_receive_run_end(sid)
    end
  end
end

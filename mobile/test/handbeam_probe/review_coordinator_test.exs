defmodule HandbeamProbe.ReviewCoordinatorTest do
  use ExUnit.Case, async: false

  alias Handbeam.Agent.Coordinator
  alias Handbeam.PubSub.Session

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
         usage: %{input_tokens: 1, output_tokens: 1}
       }}
    end

    @impl true
    def stream(messages, tool_defs, config, _on_chunk), do: complete(messages, tool_defs, config)
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "review_coord_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    host = Application.get_env(:handbeam, :host)
    Handbeam.Host.put!(%{data_dir: dir, priv_dir: Application.app_dir(:handbeam_probe, "priv")})

    vars = %{
      "HOME" => dir,
      "HANDBEAM_WORKSPACE" => Path.join(dir, "workspace"),
      "HANDBEAM_MODELS_FILE" => Path.join(dir, "models.json"),
      "HANDBEAM_WORKSPACES_FILE" => Path.join(dir, "workspaces.json"),
      "HANDBEAM_GLOBAL_SETTINGS_FILE" => Path.join(dir, "settings.json")
    }

    previous = Map.new(vars, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)

    File.write!(
      vars["HANDBEAM_MODELS_FILE"],
      Jason.encode!(%{
        "defaultProvider" => "fake",
        "defaultModel" => "fake-model",
        "providers" => %{
          "fake" => %{
            "api" => "openai-chat-completions",
            "apiKey" => "sk-fake",
            "baseUrl" => "http://127.0.0.1:9/v1",
            "models" => [%{"id" => "fake-model", "name" => "Fake"}]
          }
        }
      })
    )

    {:ok, owned} = Agent.start(fn -> [] end)
    keeper = spawn_keeper()

    on_exit(fn ->
      Enum.each(Agent.get(owned, & &1), &stop_owned!/1)
      :ok = Agent.stop(owned)
      stop_keeper!(keeper)

      if host,
        do: Application.put_env(:handbeam, :host, host),
        else: Application.delete_env(:handbeam, :host)

      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(dir)
    end)

    {:ok, _} = Handbeam.WorkspaceStore.ensure_default!()
    {:ok, owned: owned, keeper: keeper}
  end

  test "task_instructions while running is rejected and never enqueued", ctx do
    {:ok, conversation} = Handbeam.ConversationStore.create("default")
    sid = own(ctx.owned, conversation["id"])
    {:ok, _} = Session.start_or_get(session_id: sid, model: "fake")
    {:ok, queue} = Handbeam.Agent.CandidateQueue.start_link(session_id: sid, owner: ctx.keeper)
    :ok = Session.attach_run(sid, ctx.keeper, queue)

    assert {:error, :run_in_progress} =
             Coordinator.add_message(
               sid,
               "write a review",
               coord_opts(task_instructions: "skill")
             )

    assert Handbeam.Agent.CandidateQueue.get_messages(queue) == []
    assert {:ok, []} = Handbeam.ConversationTranscriptStore.list(sid)
  end

  defmodule FailingStore do
    def list(_id, _opts), do: {:ok, []}
    def append(_id, _entry, _opts), do: {:error, :disk_full}
    def update(_id, _eid, _patch, _opts), do: {:error, :disk_full}
    def replace_all(_id, _entries, _opts), do: {:error, :disk_full}
  end

  test "accepted review inbound is on disk before the provider is entered", ctx do
    {:ok, conversation} = Handbeam.ConversationStore.create("default")
    sid = own(ctx.owned, conversation["id"])
    parent = self()

    assert {:ok, %{action: :started}} =
             Coordinator.add_message(
               sid,
               "beef was tough",
               coord_opts(
                 task_instructions: "Keep negatives.",
                 provider: HoldProvider,
                 provider_config: %{notify: parent},
                 streaming: false
               )
             )

    {:ok, entries} = Handbeam.ConversationTranscriptStore.list(sid)
    assert [%{"role" => "user", "content" => "beef was tough", "delivery" => "new_run"}] = entries
    refute Enum.any?(entries, &(&1["role"] == "assistant"))

    assert_receive {:held, pid}, 5_000
    {:ok, still} = Handbeam.ConversationTranscriptStore.list(sid)
    assert Enum.map(still, & &1["role"]) == ["user"]
    send(pid, :release)
    await_run_finished!(sid)
    {:ok, flushed} = Handbeam.ConversationTranscriptStore.list(sid)
    assert Enum.any?(flushed, &(&1["role"] == "user"))
  end

  test "inbound persist failure refuses the run and starts no provider", ctx do
    {:ok, conversation} = Handbeam.ConversationStore.create("default")
    sid = own(ctx.owned, conversation["id"])
    parent = self()

    assert {:error, {:inbound_persist_failed, :disk_full}} =
             Coordinator.add_message(
               sid,
               "never sent",
               coord_opts(
                 task_instructions: "Keep negatives.",
                 transcript_store: FailingStore,
                 provider: HoldProvider,
                 provider_config: %{notify: parent},
                 streaming: false
               )
             )

    refute_received {:held, _}
    refute match?({:ok, %{running?: true}}, Coordinator.status(sid))
    assert [] == Registry.lookup(Handbeam.AgentRunRegistry, sid)
    {:ok, entries} = Handbeam.ConversationTranscriptStore.list(sid)
    assert entries == []
  end

  test "concurrent task_instructions cannot silently enqueue", ctx do
    {:ok, conversation} = Handbeam.ConversationStore.create("default")
    sid = own(ctx.owned, conversation["id"])
    parent = self()

    hold =
      coord_opts(
        provider: HoldProvider,
        provider_config: %{notify: parent},
        streaming: false
      )

    results =
      Enum.map(["first review", "second review"], fn content ->
        Task.async(fn ->
          Coordinator.add_message(sid, content, Keyword.put(hold, :task_instructions, content))
        end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.any?(results, &match?({:ok, %{action: :started}}, &1))
    assert Enum.any?(results, &match?({:error, :run_in_progress}, &1))
    refute Enum.any?(results, &match?({:ok, %{action: :enqueued}}, &1))

    receive do
      {:held, pid} -> send(pid, :release)
    after
      5_000 -> flunk("hold provider never started")
    end

    await_run_finished!(sid)

    {:ok, entries} = Handbeam.ConversationTranscriptStore.list(sid)
    user_contents = entries |> Enum.filter(&(&1["role"] == "user")) |> Enum.map(& &1["content"])
    assert length(user_contents) == 1
    assert hd(user_contents) in ["first review", "second review"]
    refute Enum.any?(entries, &(&1["content"] =~ "Task instructions"))
  end

  test "task_instructions append to the system prompt and stay out of user transcript" do
    workspace =
      Path.join(System.tmp_dir!(), "review-prompt-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    config =
      Handbeam.Agent.Config.from_opts(
        working_directory: workspace,
        task_instructions: "Keep negatives."
      )

    assert config.system_prompt =~ "You are Handbeam"
    assert config.system_prompt =~ "Keep negatives."
    File.rm_rf!(workspace)
  end

  defp coord_opts(extra) do
    {:ok, workspace} = Handbeam.WorkspaceStore.get("default")

    Keyword.merge(
      [
        workspace_path: workspace["path"],
        model: "fake/fake-model",
        provider: Handbeam.TestSupport.FakeProvider,
        provider_config: %{scenario: :simple_answer},
        tools: [],
        source: :native,
        streaming: false,
        max_turns: 2
      ],
      extra
    )
  end

  defp own(owned, sid) when is_binary(sid) do
    :ok = Agent.update(owned, &[sid | &1])
    sid
  end

  defp spawn_keeper do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_keeper!(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      send(pid, :stop)
      await_process!(pid)
    else
      :ok
    end
  end

  defp await_run_finished!(sid) do
    await_registry_down!(Handbeam.AgentRunRegistry, sid)
    await_registry_down!(Handbeam.AgentRunSupervisorRegistry, sid)
  end

  defp stop_owned!(sid) do
    case Coordinator.cancel(sid) do
      :ok -> :ok
      {:error, :not_running} -> :ok
      {:error, :not_found} -> :ok
    end

    await_run_finished!(sid)

    case Session.whereis(sid) do
      nil ->
        :ok

      pid ->
        :ok = stop_or_already_gone(Handbeam.SessionSupervisor.stop_session(sid))
        await_process!(pid)
    end
  end

  defp stop_or_already_gone(:ok), do: :ok
  defp stop_or_already_gone({:error, :not_found}), do: :ok

  defp await_registry_down!(registry, sid) do
    case Registry.lookup(registry, sid) do
      [{pid, _}] -> await_process!(pid)
      [] -> :ok
    end
  end

  defp await_process!(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    if Process.alive?(pid) do
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 ->
          flunk("expected #{inspect(pid)} to exit before host restore / cleanup")
      end
    else
      Process.demonitor(ref, [:flush])
      :ok
    end
  end
end

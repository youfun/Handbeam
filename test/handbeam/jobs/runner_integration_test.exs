defmodule Handbeam.Jobs.RunnerIntegrationTest do
  use ExUnit.Case, async: false

  alias Handbeam.Agent.{Coordinator, Message}
  alias Handbeam.Jobs

  defmodule Provider do
    @behaviour Handbeam.Agent.Provider

    def complete(messages, _defs, config) do
      if Enum.any?(messages, &(&1.role == :tool_result)) do
        send(config.notify, {:job_launched, self(), messages})

        receive do
          :finish ->
            {:ok, %{stop_reason: :end_turn, messages: [Message.assistant("done")], usage: %{}}}
        end
      else
        call = %{
          type: "tool_use",
          id: "launch-job",
          name: "bash",
          input: %{"command" => "printf ready; read -r answer", "job" => true, "wait_ms" => 100}
        }

        {:ok, %{stop_reason: :tool_use, messages: [Message.tool_use([call])], usage: %{}}}
      end
    end

    def stream(messages, defs, config, _callback), do: complete(messages, defs, config)
  end

  setup do
    old_home = System.get_env("HOME")
    dir = Path.join(System.tmp_dir!(), "job-runner-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    System.put_env("HOME", dir)
    {:ok, conversation} = Handbeam.ConversationStore.create("ws")

    on_exit(fn ->
      Coordinator.cancel(conversation["id"])
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      File.rm_rf!(dir)
    end)

    %{dir: dir, id: conversation["id"]}
  end

  for outcome <- [:completed, :cancelled] do
    test "real Runner #{outcome} closes jobs after an Executor wait returns", %{dir: dir, id: id} do
      {:ok, ack} =
        Coordinator.add_message(id, "run a job",
          workspace_path: dir,
          model: "fake",
          provider: Provider,
          provider_config: %{notify: self()},
          tools: [Handbeam.Tool.Builtin.Bash],
          source: :cli,
          middleware: [],
          mcp: false
        )

      assert_receive {:job_launched, task, messages}, 3_000
      tool_message = Enum.find(messages, &(&1.role == :tool_result))
      refute hd(tool_message.content).is_error

      context = %{
        conversation_id: id,
        run_id: ack.run_id,
        working_directory: dir,
        tool_timeout: 10_000
      }

      assert {:ok, %{jobs: [%{job_id: job_id, state: :running}]}} =
               Jobs.status(nil, 0, 500, context)

      assert {:ok, %{output: "ready", state: :running}} = Jobs.status(job_id, 0, 100, context)

      monitor = Process.monitor(ack.run_pid)
      if unquote(outcome) == :completed, do: send(task, :finish), else: Coordinator.cancel(id)
      assert_receive {:DOWN, ^monitor, :process, _, _}, 3_000

      assert {:ok, %{state: :cancelled}} =
               Jobs.status(job_id, 0, 5_000, %{context | run_id: "next-run"})
    end
  end
end

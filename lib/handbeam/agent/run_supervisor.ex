defmodule Handbeam.Agent.RunSupervisor do
  @moduledoc """
  Per-conversation run supervision tree.

  A run is an atomic unit: the queue and runner are started together, and
  `:one_for_all` ensures neither survives alone after a crash.
  """

  use Supervisor

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary
    }
  end

  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    Supervisor.start_link(__MODULE__, opts,
      name: {:via, Registry, {Handbeam.AgentRunSupervisorRegistry, conversation_id}}
    )
  end

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    queue_name = {:via, Registry, {Handbeam.AgentRunQueueRegistry, conversation_id}}

    task_supervisor_name =
      {:via, Registry, {Handbeam.AgentRunSupervisorRegistry, {:tasks, conversation_id}}}

    queue_opts = [
      session_id: conversation_id,
      owner: self(),
      name: queue_name
    ]

    runner_opts =
      opts
      |> Keyword.put(:queue_name, queue_name)
      |> Keyword.update!(:run_opts, fn run_opts ->
        run_opts
        |> Keyword.put(:run_supervisor, self())
        |> Keyword.put(:run_task_supervisor, task_supervisor_name)
      end)

    # A crashed runner, queue, or this tree must not be restarted with the
    # original input. DynamicSupervisor also uses the temporary child_spec.
    # Stopping a local process does not undo remote side effects already
    # committed; the terminal event records that the outcome is unknown.
    Supervisor.init(
      [
        Supervisor.child_spec({Handbeam.Agent.CandidateQueue, queue_opts},
          id: Handbeam.Agent.CandidateQueue,
          restart: :temporary,
          significant: true
        ),
        Supervisor.child_spec({Task.Supervisor, name: task_supervisor_name},
          id: Handbeam.Agent.RunTaskSupervisor
        ),
        Supervisor.child_spec({Handbeam.Agent.Runner, runner_opts},
          id: Handbeam.Agent.Runner,
          restart: :temporary,
          significant: true
        )
      ],
      strategy: :one_for_all,
      auto_shutdown: :any_significant,
      max_restarts: 0,
      max_seconds: 5
    )
  end
end

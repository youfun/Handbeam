defmodule Handbeam.Agent.Delegation do
  @moduledoc """
  Application-scoped owner of short, read-only delegated runs.

  Registration precedes startup. Runner's init handshake closes the lost-ack
  window; neither the tool caller nor a per-run supervisor owns cleanup.
  This is a trusted runtime policy, not a sandbox for malicious VM code.
  """
  use GenServer

  alias Handbeam.Agent.{Coordinator, Delegation.Policy}
  alias Handbeam.ConversationStore

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def run(input, context) do
    with {:ok, budget} <- Policy.validate(context) do
      GenServer.call(__MODULE__, {:run, input, context, budget}, :infinity)
    end
  catch
    :exit, _ -> {:error, "Delegation owner unavailable; completion cannot be confirmed"}
  end

  def attach(owner, id, runner), do: GenServer.call(owner, {:attach, id, runner})
  def attach_task(owner, id), do: GenServer.call(owner, {:attach_task, id, self()})

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Handbeam.PubSub, "runtime:runs")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:run, input, context, budget}, from, jobs) do
    cond do
      map_size(jobs) >= 16 ->
        {:reply, {:error, "Delegation capacity reached"}, jobs}

      Enum.any?(jobs, fn {_, job} -> job.context.run_id == context.run_id end) ->
        {:reply, {:error, "Only one child task per parent run may be active"}, jobs}

      not Policy.live_parent?(context) ->
        {:reply, {:error, "Parent run is no longer active"}, jobs}

      true ->
        id = Ecto.UUID.generate()
        run_id = Ecto.UUID.generate()
        owner = self()
        caller = elem(from, 0)
        timer = Process.send_after(self(), {:deadline, id}, budget)

        reply_timer =
          Process.send_after(self(), {:reply_deadline, id}, budget + div(context.tool_timeout, 4))

        job = %{
          id: id,
          run_id: run_id,
          context: context,
          from: from,
          parent_ref: Process.monitor(context.runner_pid),
          caller_ref: Process.monitor(caller),
          deadline_at: System.monotonic_time(:millisecond) + budget,
          timer: timer,
          reply_timer: reply_timer,
          runner: nil,
          runner_ref: nil,
          task: nil,
          status: :running,
          text: "",
          truncated?: false,
          usage: %{},
          started?: false,
          cleaned?: false,
          starter: nil,
          starter_ref: nil,
          cleanup_ref: nil
        }

        {:ok, starter} =
          Task.Supervisor.start_child(Handbeam.AgentRunTaskSupervisor, fn ->
            result = start_child(id, run_id, input, context, budget, owner)
            send(owner, {:started, id, result})
          end)

        job = %{job | starter: starter, starter_ref: Process.monitor(starter)}
        {:noreply, Map.put(jobs, id, job)}
    end
  end

  def handle_call({:attach, id, runner}, _from, jobs) do
    case jobs[id] do
      %{status: :running} = job ->
        if open?(job) do
          job = %{job | runner: runner, runner_ref: Process.monitor(runner)}
          {:reply, :ok, Map.put(jobs, id, job)}
        else
          {:reply, {:error, :parent_closed}, jobs}
        end

      _ ->
        {:reply, {:error, :delegation_closed}, jobs}
    end
  end

  def handle_call({:attach_task, id, task}, _from, jobs) do
    case jobs[id] do
      %{status: :running} = job ->
        if open?(job) do
          {:reply, :ok, Map.put(jobs, id, %{job | task: task})}
        else
          {:reply, {:error, :delegation_closed}, jobs}
        end

      _ ->
        {:reply, {:error, :delegation_closed}, jobs}
    end
  end

  @impl true
  def handle_info({:started, id, result}, jobs) do
    update_job(jobs, id, fn job ->
      job = %{job | started?: true}

      case result do
        {:ok, _} -> maybe_finish(job)
        {:error, _} -> close(job, :startup_failed)
      end
    end)
  end

  def handle_info({:child_event, id, {:message_delta, %{chunk: chunk}}}, jobs) do
    update_job(jobs, id, fn job ->
      result = Handbeam.Utils.Truncate.truncate(job.text <> chunk, :head, max_bytes: 16_000)
      %{job | text: result.content, truncated?: job.truncated? or result.truncated}
    end)
  end

  def handle_info({:child_event, id, {:delegation_usage, usage}}, jobs) do
    update_job(jobs, id, &%{&1 | usage: usage})
  end

  def handle_info({:child_event, id, {:run_end, payload}}, jobs) do
    update_job(jobs, id, fn job ->
      job = %{job | usage: Map.get(payload, :usage, job.usage)}

      close(
        job,
        if(payload[:status] in [:interrupted, "interrupted"],
          do: :blocked,
          else: payload[:status]
        )
      )
    end)
  end

  def handle_info({:deadline, id}, jobs) do
    update_job(jobs, id, &close(&1, :timed_out))
  end

  def handle_info({:reply_deadline, id}, jobs) do
    update_job(jobs, id, fn job ->
      case close(job, :timed_out) do
        nil ->
          nil

        job ->
          if job.from, do: GenServer.reply(job.from, report(job, :cleaning_up))
          %{job | from: nil}
      end
    end)
  end

  def handle_info({:cleaned, id}, jobs) do
    update_job(jobs, id, &maybe_finish(%{&1 | cleaned?: true}))
  end

  def handle_info({:retry_cleanup, id}, jobs), do: update_job(jobs, id, &cleanup/1)

  def handle_info({:run_lifecycle, parent, :run_end, payload}, jobs) do
    if payload[:status] in [:interrupted, "interrupted"] do
      {:noreply, jobs}
    else
      {:noreply,
       Enum.reduce(jobs, %{}, fn {id, job}, acc ->
         job = if job.context.conversation_id == parent, do: close(job, :parent_closed), else: job
         if job, do: Map.put(acc, id, job), else: acc
       end)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, jobs) do
    jobs =
      Enum.reduce(jobs, %{}, fn {id, job}, acc ->
        job =
          cond do
            ref in [job.parent_ref, job.caller_ref] ->
              close(job, :parent_closed)

            ref == job.runner_ref ->
              close(job, :child_stopped)

            ref == job.starter_ref ->
              job = %{job | started?: true}

              if job.status == :running and is_nil(job.runner),
                do: close(job, :startup_failed),
                else: maybe_finish(job)

            ref == job.cleanup_ref and not job.cleaned? ->
              # Cleanup worker failed; the owner retains responsibility.
              Process.send_after(self(), {:retry_cleanup, id}, 100)
              %{job | cleanup_ref: nil}

            true ->
              job
          end

        if job, do: Map.put(acc, id, job), else: acc
      end)

    {:noreply, jobs}
  end

  def handle_info(_message, jobs), do: {:noreply, jobs}

  defp update_job(jobs, id, fun) do
    case jobs[id] do
      nil ->
        {:noreply, jobs}

      job ->
        case fun.(job) do
          nil -> {:noreply, Map.delete(jobs, id)}
          updated -> {:noreply, Map.put(jobs, id, updated)}
        end
    end
  end

  defp open?(job) do
    System.monotonic_time(:millisecond) < job.deadline_at and
      Policy.live_parent?(job.context) and Process.alive?(elem(job.from, 0))
  end

  defp close(%{status: :running} = job, status) do
    Process.cancel_timer(job.timer)
    cleanup(%{job | status: status})
  end

  defp close(job, _status), do: maybe_finish(job)

  defp cleanup(job) do
    owner = self()

    {:ok, pid} =
      Task.Supervisor.start_child(Handbeam.AgentRunTaskSupervisor, fn ->
        Coordinator.cancel(job.id)

        case Handbeam.AgentRunSupervisor.stop_run(job.id) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          other -> exit({:cleanup_unconfirmed, other})
        end

        if job.task do
          ref = Process.monitor(job.task)
          Process.exit(job.task, :kill)

          receive do
            {:DOWN, ^ref, :process, _, _} -> :ok
          end
        end

        # DynamicSupervisor termination is synchronous: all child processes stopped.
        send(owner, {:cleaned, job.id})
      end)

    %{job | cleanup_ref: Process.monitor(pid)}
  end

  defp maybe_finish(%{cleaned?: true, started?: true} = job) do
    status =
      case ConversationStore.record_delegated_usage(
             job.context.conversation_id,
             job.run_id,
             job.usage
           ) do
        :ok -> job.status
        _ -> :usage_persistence_failed
      end

    if job.from, do: GenServer.reply(job.from, report(job, status))
    Process.cancel_timer(job.timer)
    Process.cancel_timer(job.reply_timer)

    for ref <- [job.parent_ref, job.caller_ref, job.runner_ref, job.starter_ref, job.cleanup_ref],
        is_reference(ref),
        do: Process.demonitor(ref, [:flush])

    nil
  end

  defp maybe_finish(job), do: job

  defp report(job, status) do
    data = %{
      status: status,
      child_conversation_id: job.id,
      child_run_id: job.run_id,
      usage: job.usage,
      report: job.text,
      report_truncated?: job.truncated?,
      usage_complete?: status in [:completed, "completed"]
    }

    text = "Delegated report (requires parent review):\n" <> Handbeam.JSON.encode!(data)
    if status in [:completed, "completed"], do: {:ok, text, data}, else: {:error, text, data}
  end

  defp start_child(id, run_id, input, context, budget, owner) do
    with {:ok, _} <-
           ConversationStore.create(context[:workspace_id],
             id: id,
             visibility: "internal",
             parent_conversation_id: context.conversation_id,
             parent_run_id: context.run_id,
             parent_tool_call_id: context.tool_call_id,
             title: "Internal read-only task"
           ) do
      opts = Policy.child_opts(context, budget)

      opts =
        opts ++
          [
            run_id: run_id,
            delegation_owner: owner,
            on_event: fn event -> send(owner, {:child_event, id, event}) end
          ]

      Coordinator.add_message(
        id,
        input["task"] <> "\n\nCompletion criteria:\n" <> input["criteria"],
        opts
      )
    end
  end
end

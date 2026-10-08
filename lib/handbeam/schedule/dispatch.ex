defmodule Handbeam.Schedule.Dispatch do
  @moduledoc """
  Turns a claimed schedule slot into one idle run, or a visible skip.

  Nothing here retries. A busy conversation, a missing model, or an unknown
  delivery stays that way until the next planned slot.
  """

  alias Handbeam.Agent.{Coordinator, RunOpts}
  alias Handbeam.ArtifactDelivery
  alias Handbeam.ConversationStore
  alias Handbeam.Schedule.{Notice, Rule, Store}
  alias Handbeam.WorkspaceStore
  alias Handbeam.Runtime.TaskTracker

  @spec run(map()) :: :ok
  def run(%{schedule: schedule, run: run} = claim) do
    cond do
      not conversation_ok?(schedule) ->
        _ = Store.disable(schedule)
        record_skip(schedule, run, "conversation_unavailable")

      not model_ok?(schedule) ->
        record_skip(schedule, run, "model_not_allowed")

      busy?(schedule.conversation_id) ->
        record_skip(schedule, run, "busy")

      true ->
        maybe_catch_up(claim)
        dispatch(claim)
    end
  end

  defp dispatch(%{schedule: schedule, run: run}) do
    case build_opts(schedule, run) do
      {:ok, content, opts} ->
        case Coordinator.add_message(schedule.conversation_id, content, opts) do
          {:ok, ack} ->
            _ =
              Store.record(run, "started",
                run_id: ack.run_id,
                reason: if(ack[:replayed], do: "replayed")
              )

            :ok

          {:error, reason} when reason in [:busy, :run_in_progress] ->
            record_skip(schedule, run, "busy")

          {:error, :delivery_unknown} ->
            _ = Store.record(run, "unknown", reason: "delivery_unknown")
            Notice.unknown(schedule, run)
            :ok

          {:error, reason} ->
            _ = Store.record(run, "failed", reason: inspect(reason))
            :ok
        end

      {:error, :model_not_allowed} ->
        record_skip(schedule, run, "model_not_allowed")

      {:error, reason} ->
        _ = Store.record(run, "failed", reason: inspect(reason))
        :ok
    end
  end

  defp build_opts(schedule, run) do
    with :ok <- model_gate(schedule),
         {:ok, workspace_path} <- workspace_path(schedule),
         {:ok, built} <-
           RunOpts.for_workspace(workspace_path, schedule.model,
             reasoning_level: schedule.reasoning_level
           ) do
      opts =
        built
        |> Keyword.merge(
          tools: schedule_tools(),
          source: :schedule,
          channel: :schedule,
          require_idle?: true,
          request_id: run.request_id,
          workspace_id: schedule.workspace_id,
          workspace_path: workspace_path,
          working_directory: workspace_path,
          streaming: true,
          origin: %{
            "kind" => "automatic",
            "source" => "schedule",
            "schedule_id" => schedule.id,
            "slot_at" => slot_iso(run)
          }
        )

      {:ok, message(schedule, run), opts}
    else
      {:error, "Model " <> _} -> {:error, :model_not_allowed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp message(schedule, run) do
    title =
      case run.slot_at do
        %DateTime{} = slot ->
          "[定时任务「#{schedule.name}」· 计划时间 #{Rule.format_local(slot, schedule.time_zone)} #{schedule.time_zone}]"

        _ ->
          "[定时任务「#{schedule.name}」· 立即运行]"
      end

    title <> "\n" <> schedule.instruction
  end

  defp schedule_tools do
    excluded = MapSet.new(["computer" | ArtifactDelivery.tool_names()])

    Enum.reject(Handbeam.Agent.default_tools(), fn module ->
      function_exported?(module, :name, 0) and module.name() in excluded
    end)
  end

  defp conversation_ok?(schedule) do
    case ConversationStore.get_meta(schedule.conversation_id) do
      {:ok, meta} ->
        meta["workspace_id"] == schedule.workspace_id and
          meta["visibility"] != "internal" and
          meta["scope"] != "free" and
          not ConversationStore.archived_conversation?(meta)

      _ ->
        false
    end
  end

  defp model_ok?(schedule) do
    case workspace_path(schedule) do
      {:ok, path} -> Handbeam.Agent.ModelConfig.model_allowed_for_workspace?(path, schedule.model)
      _ -> false
    end
  end

  defp model_gate(schedule) do
    if model_ok?(schedule), do: :ok, else: {:error, :model_not_allowed}
  end

  defp workspace_path(schedule) do
    case WorkspaceStore.get(schedule.workspace_id) do
      {:ok, %{"path" => path}} when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :conversation_unavailable}
    end
  end

  defp busy?(conversation_id) do
    coordinator_busy?(conversation_id) or task_busy?(conversation_id)
  end

  defp coordinator_busy?(conversation_id) do
    case Coordinator.status(conversation_id) do
      {:ok, status} -> busy_status?(status)
      _ -> false
    end
  end

  defp task_busy?(conversation_id) do
    Enum.any?(TaskTracker.snapshot().tasks, fn task ->
      task.conversation_id == conversation_id and
        task.status in [:running, :waiting_confirmation]
    end)
  end

  defp busy_status?(status) do
    status[:running?] == true or
      status[:status] in [:running, :awaiting_approval, :interrupted] or
      status[:interrupt_type] in [:stall_check, "stall_check"]
  end

  defp record_skip(schedule, run, reason) do
    _ = Store.record(run, "skipped", reason: reason)
    Notice.skip(schedule, run, reason)
    :ok
  end

  defp maybe_catch_up(%{missed: missed} = claim) when is_integer(missed) and missed > 0 do
    Notice.catch_up(
      claim.schedule,
      claim.skipped || claim.run,
      missed,
      claim.missed_from,
      claim.missed_to
    )
  end

  defp maybe_catch_up(_claim), do: :ok

  defp slot_iso(%{slot_at: %DateTime{} = slot}), do: DateTime.to_iso8601(slot)
  defp slot_iso(_run), do: nil
end

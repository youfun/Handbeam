defmodule Handbeam.Tool.Builtin.Schedule do
  @moduledoc """
  Create and inspect schedules bound to the current conversation.

  Identity comes from the run context. A scheduled run, a delegated run, and a
  thread handoff cannot change a schedule.
  """

  @behaviour Handbeam.Agent.Tool

  alias Handbeam.Agent.Channel
  alias Handbeam.Schedule.{Rule, Store}

  @actions ~w(list get history create update pause resume delete run_now)
  @write_actions ~w(create update pause resume delete run_now)
  @allowed ~w(action id name instruction rule time_zone model reasoning_level)

  @impl true
  def name, do: "schedule"

  @impl true
  def description do
    "Manage schedules on the current conversation only. " <>
      "create/update/run_now need an explicit rule, instruction, and IANA time zone; " <>
      "there is no default frequency. Saving a schedule does not run it. " <>
      "run_now does not move the next planned time. " <>
      "Weekly weekdays are 1=Monday through 7=Sunday. " <>
      "A scheduled run cannot create, update, pause, resume, or delete a schedule."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: %{
        action: %{type: "string", enum: @actions},
        id: %{type: "string"},
        name: %{type: "string"},
        instruction: %{type: "string"},
        rule: %{
          type: "object",
          description:
            "weekly: {kind, weekdays, times}. interval: {kind, every_minutes} with every_minutes >= 1."
        },
        time_zone: %{type: "string", description: "IANA time zone. Required when context has none."},
        model: %{type: "string", description: "Composite model id. Defaults to the current run model."},
        reasoning_level: %{type: "string"}
      }
    }
  end

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(input, context) when is_map(input) and is_map(context) do
    with :ok <- reject_unknown(input),
         {:ok, action} <- action(input),
         :ok <- write_allowed?(action, context),
         {:ok, conversation_id, workspace_id} <- identity(context) do
      perform(action, input, context, conversation_id, workspace_id)
    else
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  def execute(_, _), do: {:error, "invalid schedule input"}

  defp perform("list", _input, _context, conversation_id, _workspace_id) do
    rows =
      conversation_id
      |> Store.list_for_conversation()
      |> Enum.map(&summary/1)

    {:ok, Jason.encode!(rows)}
  end

  defp perform("get", input, _context, conversation_id, _workspace_id) do
    with {:ok, entry} <- fetch(conversation_id, input) do
      {:ok, Jason.encode!(summary(entry))}
    end
  end

  defp perform("history", input, _context, conversation_id, _workspace_id) do
    with {:ok, entry} <- fetch(conversation_id, input) do
      rows = entry.id |> Store.recent_runs(20) |> Enum.map(&run_summary/1)
      {:ok, Jason.encode!(rows)}
    end
  end

  defp perform("create", input, context, conversation_id, workspace_id) do
    with {:ok, zone} <- zone(input, context),
         {:ok, model} <- model(input, context) do
      attrs = %{
        workspace_id: workspace_id,
        conversation_id: conversation_id,
        name: field(input, "name") || "定时任务",
        instruction: field(input, "instruction"),
        rule: field(input, "rule"),
        time_zone: zone,
        model: model,
        reasoning_level: field(input, "reasoning_level"),
        created_by: "agent"
      }

      case Store.create(attrs) do
        {:ok, entry} -> {:ok, Jason.encode!(summary(entry))}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp perform("update", input, context, conversation_id, _workspace_id) do
    with {:ok, entry} <- fetch(conversation_id, input),
         {:ok, attrs} <- update_attrs(input, context, entry) do
      case Store.update(entry, attrs) do
        {:ok, updated} -> {:ok, Jason.encode!(summary(updated))}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  defp perform(action, input, _context, conversation_id, _workspace_id)
       when action in ["pause", "resume", "delete", "run_now"] do
    with {:ok, entry} <- fetch(conversation_id, input) do
      case action do
        "pause" -> finish(Store.pause(entry))
        "resume" -> finish(Store.resume(entry))
        "delete" -> finish_delete(Store.delete(entry))
        "run_now" -> run_now(entry)
      end
    end
  end

  defp perform(_action, _input, _context, _conversation_id, _workspace_id),
    do: {:error, "unknown schedule action"}

  defp run_now(entry) do
    case Store.run_now(entry) do
      {:ok, claim} ->
        Handbeam.Schedule.Dispatch.run(claim)
        {:ok, "run requested"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp finish({:ok, entry}), do: {:ok, Jason.encode!(summary(entry))}
  defp finish({:error, reason}), do: {:error, inspect(reason)}
  defp finish_delete(:ok), do: {:ok, "deleted"}
  defp finish_delete({:error, reason}), do: {:error, inspect(reason)}

  defp update_attrs(input, context, entry) do
    zone = field(input, "time_zone") || entry.time_zone

    with :ok <- if(Rule.valid_zone?(zone), do: :ok, else: {:error, :invalid_time_zone}) do
      attrs = %{
        name: field(input, "name") || entry.name,
        instruction: field(input, "instruction") || entry.instruction,
        rule: field(input, "rule") || entry.rule,
        time_zone: zone,
        reasoning_level: field(input, "reasoning_level") || entry.reasoning_level
      }

      attrs =
        case model(input, context) do
          {:ok, model} -> Map.put(attrs, :model, model)
          _ -> Map.put(attrs, :model, entry.model)
        end

      {:ok, attrs}
    end
  end

  defp fetch(conversation_id, input) do
    case field(input, "id") do
      id when is_binary(id) and id != "" -> Store.get_for_conversation(conversation_id, id)
      _ -> {:error, :not_found}
    end
  end

  defp zone(input, context) do
    zone = field(input, "time_zone") || context[:user_time_zone]

    if Rule.valid_zone?(zone), do: {:ok, zone}, else: {:error, :time_zone_required}
  end

  defp model(input, context) do
    explicit = field(input, "model")

    cond do
      is_binary(explicit) and explicit != "" ->
        {:ok, explicit}

      true ->
        opts = context[:thread_run_opts] || []
        model = opts[:model]
        provider = get_in(opts, [:provider_config, :provider_key]) || get_in(opts, [:provider_config, :provider])

        if is_binary(provider) and is_binary(model) and model != "" do
          {:ok, "#{provider}/#{model}"}
        else
          {:error, :model_required}
        end
    end
  end

  defp identity(context) do
    conversation_id = context[:conversation_id]
    workspace_id = context[:workspace_id]

    if is_binary(conversation_id) and conversation_id != "" and is_binary(workspace_id) and
         workspace_id != "" do
      {:ok, conversation_id, workspace_id}
    else
      {:error, :schedule_requires_workspace_conversation}
    end
  end

  defp write_allowed?(action, context) when action in @write_actions do
    source = context[:source] || config_source(context)
    delegated? = get_in(context, [:delegation_config, Access.key(:delegated?)]) == true
    handoff = context[:thread_handoff_id]

    if Channel.interactive?(source) and not delegated? and is_nil(handoff) do
      :ok
    else
      {:error, :schedule_changes_require_user_turn}
    end
  end

  defp write_allowed?(_action, _context), do: :ok

  defp config_source(context) do
    case context[:delegation_config] do
      %{source: source} -> source
      _ -> nil
    end
  end

  defp reject_unknown(input) do
    extra =
      input
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in @allowed))

    if extra == [] do
      :ok
    else
      {:error, "unexpected fields: #{Enum.join(extra, ", ")}"}
    end
  end

  defp action(input) do
    action = field(input, "action")

    if action in @actions do
      {:ok, action}
    else
      {:error, :unknown_action}
    end
  end

  defp field(input, key) do
    Map.get(input, key) || Map.get(input, safe_atom(key))
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp summary(entry) do
    %{
      id: entry.id,
      name: entry.name,
      instruction: entry.instruction,
      rule: entry.rule,
      description: Rule.describe(entry.rule),
      time_zone: entry.time_zone,
      model: entry.model,
      reasoning_level: entry.reasoning_level,
      status: entry.status,
      next_run_at: iso(entry.next_run_at),
      version: entry.version,
      created_by: entry.created_by
    }
  end

  defp run_summary(run) do
    %{
      id: run.id,
      slot_at: iso(run.slot_at),
      kind: run.kind,
      status: run.status,
      reason: run.reason,
      run_id: run.run_id
    }
  end

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(_), do: nil
end

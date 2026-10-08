defmodule Handbeam.Schedule.Store do
  @moduledoc """
  Persistence for schedules.

  Claim, status, and the derived next time move in one versioned write.
  A second writer either loses the version check or hits the slot unique index.
  """

  import Ecto.Query

  alias Handbeam.Repo
  alias Handbeam.Schedule.{Entry, Rule, Run}

  @spec list_for_conversation(String.t()) :: [Entry.t()]
  def list_for_conversation(conversation_id) when is_binary(conversation_id) do
    from(s in Entry,
      where: s.conversation_id == ^conversation_id,
      order_by: [asc: s.inserted_at]
    )
    |> Repo.all()
  end

  @spec get(String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case Repo.get(Entry, id) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @spec get_for_conversation(String.t(), String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  def get_for_conversation(conversation_id, id)
      when is_binary(conversation_id) and is_binary(id) do
    case Repo.get(Entry, id) do
      %Entry{conversation_id: ^conversation_id} = entry -> {:ok, entry}
      _ -> {:error, :not_found}
    end
  end

  @spec recent_runs(String.t(), pos_integer()) :: [Run.t()]
  def recent_runs(schedule_id, limit \\ 20) when is_binary(schedule_id) do
    from(r in Run,
      where: r.schedule_id == ^schedule_id,
      order_by: [desc: r.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @spec due(DateTime.t()) :: [Entry.t()]
  def due(%DateTime{} = now) do
    now = DateTime.truncate(now, :second)

    from(s in Entry,
      where: s.status == "active" and not is_nil(s.next_run_at) and s.next_run_at <= ^now,
      order_by: [asc: s.next_run_at]
    )
    |> Repo.all()
  end

  @spec earliest_next_run_at() :: DateTime.t() | nil
  def earliest_next_run_at do
    from(s in Entry,
      where: s.status == "active" and not is_nil(s.next_run_at),
      select: min(s.next_run_at)
    )
    |> Repo.one()
  end

  @spec create(map(), DateTime.t()) :: {:ok, Entry.t()} | {:error, term()}
  def create(attrs, now \\ Handbeam.Schedule.now()) when is_map(attrs) do
    with {:ok, fields} <- creation_fields(attrs, now) do
      %Entry{}
      |> Ecto.Changeset.change(fields)
      |> Repo.insert()
    end
  end

  @spec update(Entry.t(), map(), DateTime.t()) :: {:ok, Entry.t()} | {:error, term()}
  def update(%Entry{} = entry, attrs, now \\ Handbeam.Schedule.now()) when is_map(attrs) do
    Repo.transaction(fn ->
      current = Repo.get!(Entry, entry.id)

      if current.version != entry.version do
        Repo.rollback(:stale)
      else
        case update_fields(current, attrs, now) do
          {:ok, fields} ->
            {1, _} =
              from(s in Entry, where: s.id == ^current.id and s.version == ^current.version)
              |> Repo.update_all(set: fields)

            Repo.get!(Entry, current.id)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end
    end)
  end

  @spec pause(Entry.t(), DateTime.t()) :: {:ok, Entry.t()} | {:error, term()}
  def pause(%Entry{} = entry, now \\ Handbeam.Schedule.now()) do
    versioned(entry, now, fn current, now ->
      [status: "paused", next_run_at: nil, version: current.version + 1, updated_at: now]
    end)
  end

  @spec resume(Entry.t(), DateTime.t()) :: {:ok, Entry.t()} | {:error, term()}
  def resume(%Entry{} = entry, now \\ Handbeam.Schedule.now()) do
    versioned(entry, now, fn current, now ->
      case Rule.next_after(current.rule, current.time_zone, now) do
        {:ok, next} ->
          [
            status: "active",
            next_run_at: next,
            version: current.version + 1,
            updated_at: now
          ]

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @spec delete(Entry.t()) :: :ok | {:error, term()}
  def delete(%Entry{} = entry) do
    case from(s in Entry, where: s.id == ^entry.id and s.version == ^entry.version)
         |> Repo.delete_all() do
      {1, _} -> :ok
      {0, _} -> {:error, :stale}
    end
  end

  @spec disable(Entry.t(), DateTime.t()) :: {:ok, Entry.t()} | {:error, term()}
  def disable(%Entry{} = entry, now \\ Handbeam.Schedule.now()) do
    versioned(entry, now, fn current, now ->
      [status: "disabled", next_run_at: nil, version: current.version + 1, updated_at: now]
    end)
  end

  @spec claim(Entry.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def claim(%Entry{} = entry, %DateTime{} = now) do
    now = DateTime.truncate(now, :second)

    Repo.transaction(fn ->
      current = Repo.get(Entry, entry.id)

      cond do
        is_nil(current) or current.status != "active" or is_nil(current.next_run_at) ->
          Repo.rollback(:not_due)

        DateTime.compare(current.next_run_at, now) == :gt ->
          Repo.rollback(:not_due)

        true ->
          case Rule.latest_due(current.rule, current.time_zone, current.next_run_at, now) do
            :not_due ->
              Repo.rollback(:not_due)

            {:error, reason} ->
              Repo.rollback(reason)

            {:ok, due} ->
              insert_claim(current, due, now)
          end
      end
    end)
    |> normalize_claim()
  end

  @spec run_now(Entry.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def run_now(%Entry{} = entry, now \\ Handbeam.Schedule.now()) do
    now = DateTime.truncate(now, :second)

    Repo.transaction(fn ->
      current = Repo.get(Entry, entry.id)

      if is_nil(current) or current.version != entry.version do
        Repo.rollback(:stale)
      else
        run = %Run{
          id: Ecto.UUID.generate(),
          schedule_id: current.id,
          slot_at: nil,
          kind: "manual",
          request_id: "sched-#{current.id}-manual-#{Ecto.UUID.generate()}",
          status: "claimed",
          inserted_at: now,
          updated_at: now
        }

        case Repo.insert(run) do
          {:ok, run} -> %{schedule: current, run: run, missed: 0}
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end
    end)
  end

  @spec record(Run.t(), String.t(), keyword()) :: {:ok, Run.t()} | {:error, :not_found}
  def record(%Run{} = run, status, opts \\ []) when is_binary(status) do
    now = Keyword.get(opts, :now, Handbeam.Schedule.now()) |> DateTime.truncate(:second)
    reason = Keyword.get(opts, :reason)
    run_id = Keyword.get(opts, :run_id, run.run_id)

    {count, _} =
      from(r in Run, where: r.id == ^run.id and r.status == ^run.status)
      |> Repo.update_all(set: [status: status, reason: reason, run_id: run_id, updated_at: now])

    if count == 1, do: {:ok, Repo.get!(Run, run.id)}, else: {:error, :not_found}
  end

  @spec finish_by_run_id(String.t(), String.t(), String.t() | nil) :: :ok
  def finish_by_run_id(run_id, status, reason)
      when is_binary(run_id) and is_binary(status) do
    now = DateTime.truncate(Handbeam.Schedule.now(), :second)

    from(r in Run, where: r.run_id == ^run_id and r.status == "started")
    |> Repo.update_all(set: [status: status, reason: reason, updated_at: now])

    :ok
  end

  @spec recover_unknown(DateTime.t(), (String.t(), String.t() -> boolean())) :: [Run.t()]
  def recover_unknown(%DateTime{} = now, alive?) when is_function(alive?, 2) do
    now = DateTime.truncate(now, :second)
    claimed = from(r in Run, where: r.status == "claimed") |> Repo.all()

    started =
      from(r in Run, where: r.status == "started" and not is_nil(r.run_id))
      |> Repo.all()
      |> Enum.reject(fn run ->
        entry = Repo.get!(Entry, run.schedule_id)
        alive?.(entry.conversation_id, run.run_id)
      end)

    Enum.map(claimed ++ started, fn run ->
      {:ok, updated} = record(run, "unknown", now: now, reason: "delivery_unknown")
      updated
    end)
  end

  defp insert_claim(current, due, now) do
    {count, _} =
      from(s in Entry,
        where: s.id == ^current.id and s.version == ^current.version and s.status == "active"
      )
      |> Repo.update_all(
        set: [next_run_at: due.next_run_at, version: current.version + 1, updated_at: now]
      )

    if count == 0 do
      Repo.rollback(:conflict)
    else
      run = %Run{
        id: Ecto.UUID.generate(),
        schedule_id: current.id,
        slot_at: due.slot,
        kind: if(due.missed > 0, do: "catch_up", else: "scheduled"),
        request_id: request_id(current.id, due.slot),
        status: "claimed",
        inserted_at: now,
        updated_at: now
      }

      case insert_run(run) do
        {:ok, run} ->
          skipped = maybe_skip(current, due, now)
          schedule = Repo.get!(Entry, current.id)

          %{
            schedule: schedule,
            run: run,
            skipped: skipped,
            missed: due.missed,
            missed_from: due.missed_from,
            missed_to: due.missed_to
          }

        {:error, :already_claimed} ->
          Repo.rollback(:already_claimed)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end
  end

  defp insert_run(run) do
    Repo.insert(run)
  rescue
    Ecto.ConstraintError -> {:error, :already_claimed}
  end

  defp maybe_skip(_current, %{missed: 0}, _now), do: nil

  defp maybe_skip(current, due, now) do
    reason =
      "missed:#{due.missed}|#{DateTime.to_iso8601(due.missed_from)}|#{DateTime.to_iso8601(due.missed_to)}"

    run = %Run{
      id: Ecto.UUID.generate(),
      schedule_id: current.id,
      slot_at: nil,
      kind: "scheduled",
      request_id: "sched-#{current.id}-missed-#{DateTime.to_unix(due.slot)}",
      status: "skipped",
      reason: reason,
      inserted_at: now,
      updated_at: now
    }

    {:ok, skipped} = Repo.insert(run)
    skipped
  end

  defp request_id(schedule_id, %DateTime{} = slot) do
    "sched-#{schedule_id}-#{DateTime.to_unix(slot)}"
  end

  defp normalize_claim({:ok, claim}), do: {:ok, claim}

  defp normalize_claim({:error, %Ecto.Changeset{} = changeset}) do
    if changeset.errors[:slot_at] || constraint?(changeset),
      do: {:error, :already_claimed},
      else: {:error, changeset}
  end

  defp normalize_claim(other), do: other

  defp constraint?(changeset) do
    Enum.any?(changeset.constraints, &(&1.constraint == "schedule_runs_slot_unique"))
  end

  defp versioned(%Entry{} = entry, now, fun) do
    now = DateTime.truncate(now, :second)

    Repo.transaction(fn ->
      current = Repo.get(Entry, entry.id)

      if is_nil(current) or current.version != entry.version do
        Repo.rollback(:stale)
      else
        case fun.(current, now) do
          {:error, reason} ->
            Repo.rollback(reason)

          fields when is_list(fields) ->
            {1, _} =
              from(s in Entry, where: s.id == ^current.id and s.version == ^current.version)
              |> Repo.update_all(set: fields)

            Repo.get!(Entry, current.id)
        end
      end
    end)
  end

  defp creation_fields(attrs, now) do
    now = DateTime.truncate(now, :second)
    rule = Map.get(attrs, :rule) || Map.get(attrs, "rule")
    zone = Map.get(attrs, :time_zone) || Map.get(attrs, "time_zone")
    instruction = Map.get(attrs, :instruction) || Map.get(attrs, "instruction")
    model = Map.get(attrs, :model) || Map.get(attrs, "model")
    name = Map.get(attrs, :name) || Map.get(attrs, "name") || "定时任务"

    with {:ok, rule} <- Rule.validate(rule),
         :ok <- required(instruction, :instruction),
         :ok <- required(model, :model),
         :ok <- zone_ok(zone),
         {:ok, next} <- Rule.next_after(rule, zone, now) do
      {:ok,
       %{
         id: Ecto.UUID.generate(),
         workspace_id: Map.get(attrs, :workspace_id) || Map.get(attrs, "workspace_id"),
         conversation_id: Map.get(attrs, :conversation_id) || Map.get(attrs, "conversation_id"),
         name: name,
         instruction: instruction,
         rule: dump_rule(rule),
         time_zone: zone,
         model: model,
         reasoning_level: Map.get(attrs, :reasoning_level) || Map.get(attrs, "reasoning_level"),
         status: "active",
         next_run_at: next,
         version: 1,
         created_by: Map.get(attrs, :created_by) || Map.get(attrs, "created_by") || "user",
         inserted_at: now,
         updated_at: now
       }}
    end
  end

  defp update_fields(current, attrs, now) do
    rule = Map.get(attrs, :rule, current.rule)
    zone = Map.get(attrs, :time_zone, current.time_zone)
    instruction = Map.get(attrs, :instruction, current.instruction)
    name = Map.get(attrs, :name, current.name)
    model = Map.get(attrs, :model, current.model)
    reasoning = Map.get(attrs, :reasoning_level, current.reasoning_level)

    with {:ok, rule} <- Rule.validate(rule),
         :ok <- required(instruction, :instruction),
         :ok <- required(model, :model),
         :ok <- zone_ok(zone),
         {:ok, next} <- maybe_recompute(current, rule, zone, now) do
      {:ok,
       [
         name: name,
         instruction: instruction,
         rule: dump_rule(rule),
         time_zone: zone,
         model: model,
         reasoning_level: reasoning,
         next_run_at: next,
         version: current.version + 1,
         updated_at: DateTime.truncate(now, :second)
       ]}
    end
  end

  defp maybe_recompute(current, rule, zone, now) do
    same? = dump_rule(rule) == stringify_rule(current.rule) and zone == current.time_zone

    cond do
      same? and not is_nil(current.next_run_at) -> {:ok, current.next_run_at}
      true -> Rule.next_after(rule, zone, now)
    end
  end

  defp dump_rule(%{kind: :weekly, weekdays: days, times: times}) do
    %{
      "kind" => "weekly",
      "weekdays" => days,
      "times" => Enum.map(times, &format_time/1)
    }
  end

  defp dump_rule(%{kind: :interval, every_minutes: minutes}) do
    %{"kind" => "interval", "every_minutes" => minutes}
  end

  defp stringify_rule(rule) when is_map(rule) do
    case Rule.validate(rule) do
      {:ok, normalized} -> dump_rule(normalized)
      _ -> rule
    end
  end

  defp format_time({hour, minute}) do
    :io_lib.format("~2..0B:~2..0B", [hour, minute]) |> IO.iodata_to_binary()
  end

  defp required(value, _key) when is_binary(value) and value != "", do: :ok
  defp required(_value, key), do: {:error, key}

  defp zone_ok(zone) do
    if Rule.valid_zone?(zone), do: :ok, else: {:error, :invalid_time_zone}
  end
end

defmodule Handbeam.Schedule.Rule do
  @moduledoc """
  Frequency rules for a schedule.

  Two kinds only: weekly clock times in an IANA zone, or a fixed interval.
  A missing local time (spring forward) uses the first valid instant after the
  gap. A repeated local time (fall back) uses the earlier instant.
  """

  @min_interval 1
  @weekdays 1..7

  @type rule :: map()
  @type due :: %{
          slot: DateTime.t(),
          missed: non_neg_integer(),
          missed_from: DateTime.t() | nil,
          missed_to: DateTime.t() | nil,
          next_run_at: DateTime.t()
        }

  @spec validate(term()) :: {:ok, rule()} | {:error, term()}
  def validate(rule), do: normalize(rule)

  @spec next_after(rule(), String.t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, term()}
  def next_after(rule, time_zone, %DateTime{} = utc) do
    with {:ok, rule} <- normalize(rule),
         :ok <- zone(time_zone) do
      {:ok, advance(rule, time_zone, truncate(utc))}
    end
  end

  @spec latest_due(rule(), String.t(), DateTime.t(), DateTime.t()) ::
          {:ok, due()} | :not_due | {:error, term()}
  def latest_due(rule, time_zone, %DateTime{} = from, %DateTime{} = now) do
    from = truncate(from)
    now = truncate(now)

    with {:ok, rule} <- normalize(rule),
         :ok <- zone(time_zone) do
      if DateTime.compare(from, now) == :gt do
        :not_due
      else
        collect(rule, time_zone, from, now, [])
      end
    end
  end

  @spec upcoming(rule(), String.t(), DateTime.t(), pos_integer()) ::
          {:ok, [DateTime.t()]} | {:error, term()}
  def upcoming(rule, time_zone, %DateTime{} = from, count) when is_integer(count) and count > 0 do
    with {:ok, first} <- next_after(rule, time_zone, from) do
      {:ok, unfold(rule, time_zone, first, count, [])}
    end
  end

  @spec describe(rule()) :: String.t()
  def describe(rule) do
    case normalize(rule) do
      {:ok, %{kind: :interval, every_minutes: minutes}} ->
        describe_interval(minutes)

      {:ok, %{kind: :weekly, weekdays: days, times: times}} ->
        describe_weekly(days, times)

      _ ->
        "无效规则"
    end
  end

  @spec valid_zone?(term()) :: boolean()
  def valid_zone?(name) when is_binary(name) and name != "" do
    match?(:ok, zone(name))
  end

  def valid_zone?(_), do: false

  @spec format_local(DateTime.t(), String.t()) :: String.t()
  def format_local(%DateTime{} = utc, time_zone) do
    case DateTime.shift_zone(truncate(utc), time_zone) do
      {:ok, local} -> Calendar.strftime(local, "%Y-%m-%d %H:%M")
      _ -> Calendar.strftime(truncate(utc), "%Y-%m-%d %H:%M UTC")
    end
  end

  defp unfold(_rule, _tz, _slot, 0, acc), do: Enum.reverse(acc)

  defp unfold(rule, tz, slot, count, acc) do
    next = advance(rule, tz, slot)
    unfold(rule, tz, next, count - 1, [slot | acc])
  end

  defp collect(rule, tz, slot, now, earlier) do
    next = advance(rule, tz, slot)

    cond do
      DateTime.compare(slot, now) == :gt ->
        finish(Enum.reverse(earlier), slot)

      DateTime.compare(next, slot) != :gt ->
        {:error, :rule_did_not_advance}

      true ->
        collect(rule, tz, next, now, [slot | earlier])
    end
  end

  defp finish([], _next), do: :not_due

  defp finish(slots, next) do
    {missed, [slot]} = Enum.split(slots, -1)

    {:ok,
     %{
       slot: slot,
       missed: length(missed),
       missed_from: List.first(missed),
       missed_to: List.last(missed),
       next_run_at: next
     }}
  end

  defp advance(%{kind: :interval, every_minutes: minutes}, _tz, utc) do
    DateTime.add(utc, minutes * 60, :second)
  end

  defp advance(%{kind: :weekly} = rule, tz, utc) do
    local = DateTime.shift_zone!(utc, tz)
    start = Date.add(DateTime.to_date(local), -1)

    Enum.find_value(0..14, fn offset ->
      date = Date.add(start, offset)

      if Date.day_of_week(date) in rule.weekdays do
        Enum.find_value(rule.times, fn time ->
          occurrence = local_occurrence(date, time, tz)
          if DateTime.compare(occurrence, utc) == :gt, do: occurrence
        end)
      end
    end) || DateTime.add(utc, 24 * 3600, :second)
  end

  defp local_occurrence(date, {hour, minute}, tz) do
    {:ok, naive} = NaiveDateTime.new(date, Time.new!(hour, minute, 0))

    utc =
      case DateTime.from_naive(naive, tz) do
        {:ok, dt} -> dt
        {:ambiguous, earlier, _later} -> earlier
        {:gap, _before, just_after} -> just_after
      end

    utc
    |> DateTime.shift_zone!("Etc/UTC")
    |> truncate()
  end

  defp normalize(%{kind: kind} = rule), do: normalize(stringify(rule) |> Map.put("kind", kind))

  defp normalize(%{"kind" => kind} = rule) when kind in ["weekly", :weekly] do
    with {:ok, days} <- weekdays(rule["weekdays"] || rule[:weekdays]),
         {:ok, times} <- times(rule["times"] || rule[:times]) do
      {:ok, %{kind: :weekly, weekdays: days, times: times}}
    end
  end

  defp normalize(%{"kind" => kind} = rule) when kind in ["interval", :interval] do
    case integer(rule["every_minutes"] || rule[:every_minutes]) do
      minutes when is_integer(minutes) and minutes >= @min_interval ->
        {:ok, %{kind: :interval, every_minutes: minutes}}

      _ ->
        {:error, :invalid_interval}
    end
  end

  defp normalize(_), do: {:error, :invalid_rule}

  defp weekdays(days) when is_list(days) and days != [] do
    parsed = Enum.map(days, &integer/1)

    if Enum.all?(parsed, &(&1 in @weekdays)) and parsed == Enum.uniq(parsed) do
      {:ok, Enum.sort(parsed)}
    else
      {:error, :invalid_weekdays}
    end
  end

  defp weekdays(_), do: {:error, :invalid_weekdays}

  defp times(times) when is_list(times) and times != [] do
    parsed = Enum.map(times, &parse_time/1)

    cond do
      Enum.any?(parsed, &(&1 == :error)) ->
        {:error, :invalid_times}

      parsed != Enum.uniq(parsed) ->
        {:error, :invalid_times}

      true ->
        {:ok, Enum.sort(parsed)}
    end
  end

  defp times(_), do: {:error, :invalid_times}

  defp parse_time(value) when is_binary(value) do
    case String.split(value, ":") do
      [hour, minute] ->
        with {hour, ""} <- Integer.parse(hour),
             {minute, ""} <- Integer.parse(minute),
             true <- hour in 0..23 and minute in 0..59 do
          {hour, minute}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_time({hour, minute}) when hour in 0..23 and minute in 0..59, do: {hour, minute}
  defp parse_time(_), do: :error

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> :error
    end
  end

  defp integer(_), do: :error

  defp zone(name) when is_binary(name) and name != "" do
    case DateTime.now(name) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_time_zone}
    end
  end

  defp zone(_), do: {:error, :invalid_time_zone}

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp truncate(%DateTime{} = dt), do: DateTime.truncate(dt, :second)

  defp describe_interval(minutes) when rem(minutes, 60) == 0 and div(minutes, 60) > 1 do
    "每 #{div(minutes, 60)} 小时"
  end

  defp describe_interval(60), do: "每 1 小时"
  defp describe_interval(1), do: "每 1 分钟"
  defp describe_interval(minutes), do: "每 #{minutes} 分钟"

  defp describe_weekly(days, times) do
    prefix = if days == Enum.to_list(1..7), do: "每天", else: "每周" <> weekday_labels(days)
    prefix <> " " <> Enum.map_join(times, "、", &format_time/1)
  end

  defp weekday_labels(days) do
    names = %{1 => "一", 2 => "二", 3 => "三", 4 => "四", 5 => "五", 6 => "六", 7 => "日"}
    Enum.map_join(days, "、", &Map.fetch!(names, &1))
  end

  defp format_time({hour, minute}) do
    :io_lib.format("~2..0B:~2..0B", [hour, minute]) |> IO.iodata_to_binary()
  end
end

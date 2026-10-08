defmodule HandbeamWeb.WorkspaceLive.Schedules do
  @moduledoc false

  use HandbeamWeb, :html

  alias Handbeam.Schedule.{Rule, Store}
  alias Phoenix.LiveView.JS

  def defaults(socket) do
    tz =
      case Phoenix.LiveView.get_connect_params(socket) do
        %{"time_zone" => zone} when is_binary(zone) -> zone
        _ -> nil
      end

    socket
    |> Phoenix.Component.assign(:user_time_zone, tz)
    |> Phoenix.Component.assign(:show_schedules, false)
    |> Phoenix.Component.assign(:schedule_draft, nil)
    |> Phoenix.Component.assign(:schedule_error, nil)
    |> Phoenix.Component.assign(:schedules, [])
    |> Phoenix.Component.assign(:schedule_runs, %{})
  end

  def toggle(socket) do
    show = not socket.assigns.show_schedules

    socket
    |> Phoenix.Component.assign(:show_schedules, show)
    |> Phoenix.Component.assign(:schedule_error, nil)
    |> reload()
  end

  def reload(socket) do
    id = socket.assigns.current_conversation_id

    if socket.assigns.chat_scope == :workspace and is_binary(id) do
      schedules = Store.list_for_conversation(id)

      runs =
        Map.new(schedules, fn entry ->
          {entry.id, Store.recent_runs(entry.id, 20)}
        end)

      socket
      |> Phoenix.Component.assign(:schedules, schedules)
      |> Phoenix.Component.assign(:schedule_runs, runs)
    else
      socket
    end
  end

  def create(socket, params) do
    with {:ok, attrs} <- form_attrs(socket, params),
         {:ok, _entry} <- Store.create(attrs) do
      socket
      |> Phoenix.Component.assign(:schedule_draft, nil)
      |> Phoenix.Component.assign(:schedule_error, nil)
      |> reload()
    else
      {:error, reason} -> Phoenix.Component.assign(socket, :schedule_error, inspect(reason))
    end
  end

  def update(socket, params) do
    with {:ok, entry} <- current(socket, params["schedule_id"]),
         {:ok, attrs} <- form_attrs(socket, params),
         {:ok, _} <- Store.update(entry, attrs) do
      socket
      |> Phoenix.Component.assign(:schedule_draft, nil)
      |> Phoenix.Component.assign(:schedule_error, nil)
      |> reload()
    else
      {:error, reason} -> Phoenix.Component.assign(socket, :schedule_error, inspect(reason))
    end
  end

  def pause(socket, id), do: mutate(socket, id, &Store.pause/1)
  def resume(socket, id), do: mutate(socket, id, &Store.resume/1)

  def delete(socket, id) do
    with {:ok, entry} <- current(socket, id),
         :ok <- Store.delete(entry) do
      reload(socket)
    else
      {:error, reason} -> Phoenix.Component.assign(socket, :schedule_error, inspect(reason))
    end
  end

  def run_now(socket, id) do
    with {:ok, entry} <- current(socket, id),
         {:ok, claim} <- Store.run_now(entry) do
      Handbeam.Schedule.Dispatch.run(claim)
      reload(socket)
    else
      {:error, reason} -> Phoenix.Component.assign(socket, :schedule_error, inspect(reason))
    end
  end

  def edit(socket, id) do
    case current(socket, id) do
      {:ok, entry} -> Phoenix.Component.assign(socket, :schedule_draft, entry)
      {:error, reason} -> Phoenix.Component.assign(socket, :schedule_error, inspect(reason))
    end
  end

  attr :chat_scope, :any, required: true
  attr :show, :boolean, required: true
  attr :schedules, :list, required: true
  attr :runs, :map, required: true
  attr :draft, :any, default: nil
  attr :error, :any, default: nil
  attr :time_zone, :any, default: nil
  attr :models, :list, default: []
  attr :selected_model, :any, default: nil

  def panel(assigns) do
    ~H"""
    <div :if={@chat_scope == :workspace} class="absolute top-3 right-6 z-30">
      <button
        id="schedule-toggle"
        type="button"
        phx-click="toggle_schedules"
        class="text-xs border rounded px-2 py-1 bg-surface text-secondary hover:text-primary"
      >
        {gettext("定时任务")}
      </button>
    </div>
    <aside
      :if={@show and @chat_scope == :workspace}
      id="schedule-panel"
      class="absolute top-12 right-4 z-30 w-[360px] max-h-[70vh] overflow-y-auto bg-surface border rounded-xl shadow-xl p-4 space-y-3"
    >
      <div class="flex items-center justify-between">
        <h3 class="text-sm font-semibold">{gettext("定时任务")}</h3>
        <button type="button" phx-click="toggle_schedules" class="text-xs text-secondary">
          {gettext("关闭")}
        </button>
      </div>
      <p :if={@error} class="text-xs text-error">{@error}</p>
      <div :for={entry <- @schedules} id={"schedule-#{entry.id}"} class="border rounded-lg p-3 space-y-2">
        <div class="text-sm font-medium">{entry.name}</div>
        <div class="text-xs text-secondary">
          {Rule.describe(entry.rule)} · {entry.time_zone}
        </div>
        <div class="text-xs">
          {gettext("下次")}：{next_label(entry, @time_zone)} · {entry.status}
        </div>
        <div class="flex flex-wrap gap-2 text-xs">
          <button type="button" phx-click="schedule_pause" phx-value-id={entry.id}>{gettext("暂停")}</button>
          <button type="button" phx-click="schedule_resume" phx-value-id={entry.id}>{gettext("恢复")}</button>
          <button type="button" phx-click="schedule_run_now" phx-value-id={entry.id}>{gettext("立即运行")}</button>
          <button type="button" phx-click="schedule_edit" phx-value-id={entry.id}>{gettext("编辑")}</button>
          <button type="button" phx-click="schedule_delete" phx-value-id={entry.id}>{gettext("删除")}</button>
        </div>
        <ul class="text-xs text-secondary space-y-1">
          <li :for={run <- Map.get(@runs, entry.id, [])}>
            {run_label(run, entry.time_zone)} · {run.kind} · {run.status}
            <span :if={run.reason}> · {run.reason}</span>
            <button
              :if={run.run_id}
              type="button"
              phx-click={JS.dispatch("phx:scroll-to-run", to: "window", detail: %{run_id: run.run_id})}
              class="underline"
            >
              {run.run_id}
            </button>
          </li>
        </ul>
      </div>
      <.form for={%{}} id="schedule-form" phx-submit={if @draft, do: "schedule_update", else: "schedule_create"} class="space-y-2">
        <input :if={@draft} type="hidden" name="schedule_id" value={@draft.id} />
        <input name="name" value={@draft && @draft.name} placeholder={gettext("名称")} class="w-full text-xs border rounded px-2 py-1" />
        <select name="kind" class="w-full text-xs border rounded px-2 py-1">
          <option value="daily">{gettext("每天")}</option>
          <option value="weekly">{gettext("每周")}</option>
          <option value="interval">{gettext("每隔")}</option>
        </select>
        <input name="weekdays" value="1,2,3,4,5" placeholder="1,2,3,4,5" class="w-full text-xs border rounded px-2 py-1" />
        <input name="times" value={times_value(@draft)} placeholder="09:00" class="w-full text-xs border rounded px-2 py-1" />
        <input name="every_hours" value="1" placeholder={gettext("小时间隔")} class="w-full text-xs border rounded px-2 py-1" />
        <input name="time_zone" value={(@draft && @draft.time_zone) || @time_zone} placeholder="Asia/Shanghai" class="w-full text-xs border rounded px-2 py-1" />
        <textarea name="instruction" rows="3" class="w-full text-xs border rounded px-2 py-1">{@draft && @draft.instruction}</textarea>
        <select name="model" class="w-full text-xs border rounded px-2 py-1">
          <option :for={model <- @models} value={model.id} selected={model.id == ((@draft && @draft.model) || @selected_model)}>
            {model.name || model.id}
          </option>
        </select>
        <button type="submit" class="text-xs bg-user text-white rounded px-3 py-1">
          {if @draft, do: gettext("保存"), else: gettext("新建")}
        </button>
      </.form>
    </aside>
    """
  end

  defp mutate(socket, id, fun) do
    with {:ok, entry} <- current(socket, id),
         {:ok, _} <- fun.(entry) do
      reload(socket)
    else
      {:error, reason} -> Phoenix.Component.assign(socket, :schedule_error, inspect(reason))
    end
  end

  defp current(socket, id) do
    Store.get_for_conversation(socket.assigns.current_conversation_id, id)
  end

  defp form_attrs(socket, params) do
    zone = params["time_zone"] || socket.assigns.user_time_zone

    rule =
      case params["kind"] do
        "interval" ->
          hours = parse_int(params["every_hours"], 1)
          %{"kind" => "interval", "every_minutes" => max(hours, 1) * 60}

        "weekly" ->
          %{"kind" => "weekly", "weekdays" => parse_days(params["weekdays"]), "times" => parse_times(params["times"])}

        _ ->
          %{"kind" => "weekly", "weekdays" => [1, 2, 3, 4, 5, 6, 7], "times" => parse_times(params["times"])}
      end

    {:ok,
     %{
       workspace_id: socket.assigns.current_workspace_id,
       conversation_id: socket.assigns.current_conversation_id,
       name: blank(params["name"], "定时任务"),
       instruction: params["instruction"],
       rule: rule,
       time_zone: zone,
       model: blank(params["model"], socket.assigns.selected_model),
       reasoning_level: socket.assigns.selected_reasoning_level,
       created_by: "user"
     }}
  end

  defp next_label(%{next_run_at: nil}, _zone), do: "—"

  defp next_label(entry, zone) do
    Rule.format_local(entry.next_run_at, zone || entry.time_zone)
  end

  defp run_label(run, zone) do
    if run.slot_at, do: Rule.format_local(run.slot_at, zone), else: gettext("立即运行")
  end

  defp times_value(%{rule: %{"times" => times}}) when is_list(times), do: Enum.join(times, ",")
  defp times_value(_), do: "09:00"

  defp parse_days(nil), do: [1, 2, 3, 4, 5]

  defp parse_days(text) do
    text
    |> String.split(~r/[, ]+/, trim: true)
    |> Enum.map(&String.to_integer/1)
  end

  defp parse_times(nil), do: ["09:00"]

  defp parse_times(text) do
    text
    |> String.split(~r/[, ]+/, trim: true)
    |> case do
      [] -> ["09:00"]
      times -> times
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(text, default) do
    case Integer.parse(to_string(text)) do
      {n, _} -> n
      _ -> default
    end
  end

  defp blank(value, fallback) when value in [nil, ""], do: fallback
  defp blank(value, _fallback), do: value
end

defmodule HandbeamWeb.WorkspaceLive.Schedules do
  @moduledoc false

  use HandbeamWeb, :html

  alias Handbeam.Schedule.{Presentation, Rule, Store}
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
    |> Phoenix.Component.assign(:schedule_request, "")
    |> Phoenix.Component.assign(:schedule_error, nil)
    |> Phoenix.Component.assign(:schedules, [])
    |> Phoenix.Component.assign(:schedule_runs, %{})
    |> Phoenix.Component.assign(:schedule_once_entries, [])
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

      once_entries = load_once_entries(id)

      socket
      |> Phoenix.Component.assign(:schedules, schedules)
      |> Phoenix.Component.assign(:schedule_runs, runs)
      |> Phoenix.Component.assign(:schedule_once_entries, once_entries)
    else
      socket
    end
  end

  def prepare_ask(socket, text) do
    text = text |> to_string() |> String.trim()

    if text == "" do
      {:error, Phoenix.Component.assign(socket, :schedule_error, gettext("先说清何时、做什么"))}
    else
      {:ok,
       socket
       |> Phoenix.Component.assign(:schedule_request, "")
       |> Phoenix.Component.assign(:schedule_error, nil), text}
    end
  end

  def remember_request(socket, text) do
    Phoenix.Component.assign(socket, :schedule_request, to_string(text || ""))
  end

  def revise(socket, id) do
    case current(socket, id) do
      {:ok, entry} ->
        socket
        |> Phoenix.Component.assign(:schedule_request, revise_prompt(entry))
        |> Phoenix.Component.assign(:schedule_error, nil)

      {:error, reason} ->
        Phoenix.Component.assign(socket, :schedule_error, inspect(reason))
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

  attr :chat_scope, :any, required: true
  attr :show, :boolean, required: true
  attr :schedules, :list, required: true
  attr :runs, :map, required: true
  attr :request, :string, default: ""
  attr :error, :any, default: nil
  attr :time_zone, :any, default: nil

  def panel(assigns) do
    ~H"""
    <div :if={@chat_scope == :workspace} class="schedule-launcher">
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
      class="schedule-panel overflow-y-auto bg-surface border rounded-xl shadow-xl p-4 space-y-3"
    >
      <div class="flex items-center justify-between">
        <h3 class="text-sm font-semibold">{gettext("定时任务")}</h3>
        <button type="button" phx-click="toggle_schedules" class="text-xs text-secondary">
          {gettext("关闭")}
        </button>
      </div>
      <p :if={@error} class="text-xs text-error">{@error}</p>
      <div
        :for={entry <- @schedules}
        id={"schedule-#{entry.id}"}
        class="border rounded-lg p-3 space-y-2"
      >
        <div class="text-sm font-medium">{entry.name}</div>
        <div class="text-xs text-secondary">
          {sidebar_summary(entry, @runs)}
        </div>
        <div class="text-xs">
          {sidebar_status(entry, @runs, @time_zone)}
        </div>
        <% view = once_view(entry, Map.get(@runs, entry.id, [])) %>
        <div :if={view} class="flex flex-wrap gap-2 text-xs">
          <button
            :if={view.action == :pause}
            type="button"
            phx-click="schedule_pause"
            phx-value-id={entry.id}
          >
            {gettext("暂停")}
          </button>
          <button
            :if={view.action == :resume}
            type="button"
            phx-click="schedule_resume"
            phx-value-id={entry.id}
          >
            {gettext("恢复")}
          </button>
          <button type="button" phx-click="schedule_delete" phx-value-id={entry.id}>
            {gettext("删除")}
          </button>
        </div>
        <div :if={!view} class="flex flex-wrap gap-2 text-xs">
          <button type="button" phx-click="schedule_pause" phx-value-id={entry.id}>{gettext("暂停")}</button>
          <button type="button" phx-click="schedule_resume" phx-value-id={entry.id}>{gettext("恢复")}</button>
          <button type="button" phx-click="schedule_run_now" phx-value-id={entry.id}>{gettext("立即运行")}</button>
          <button type="button" phx-click="schedule_revise" phx-value-id={entry.id}>{gettext("改一下")}</button>
          <button type="button" phx-click="schedule_delete" phx-value-id={entry.id}>{gettext("删除")}</button>
        </div>
        <ul class="text-xs text-secondary space-y-1">
          <li :for={run <- Map.get(@runs, entry.id, [])}>
            {run_label(run, entry.time_zone)} · {run.kind} · {run.status}
            <span :if={run.reason}> · {run.reason}</span>
            <button
              :if={run.run_id}
              type="button"
              phx-click={
                JS.dispatch("phx:scroll-to-run", to: "window", detail: %{run_id: run.run_id})
              }
              class="underline"
            >
              {run.run_id}
            </button>
          </li>
        </ul>
      </div>
      <form
        id="schedule-ask"
        phx-submit="schedule_ask"
        phx-change="schedule_request"
        class="space-y-2"
      >
        <p class="text-xs text-secondary">
          {gettext("在这个对话里用一句话说何时、做什么。改频率、时间或语言，也直接说。")}
        </p>
        <textarea
          id="schedule-request"
          name="request"
          rows="3"
          value={@request}
          placeholder={gettext("工作日每天 09:00，把摘要发到这个聊天")}
          class="w-full text-xs border rounded px-2 py-1"
        ></textarea>
        <button type="submit" class="text-xs bg-user text-white rounded px-3 py-1">
          {gettext("发给这个对话")}
        </button>
      </form>
    </aside>
    """
  end

  attr :schedules, :list, default: []
  attr :runs, :map, default: %{}
  attr :timeline, :list, default: []

  def composer_once_cards(assigns) do
    assigns =
      assign(assigns, :cards, dock_cards(assigns.schedules, assigns.runs, assigns.timeline))

    ~H"""
    <div :if={@cards != []} id="once-schedule-dock" class="once-schedule-dock">
      <.once_card :for={card <- @cards} card={card} />
    </div>
    """
  end

  attr :card, :map, required: true

  def once_card(assigns) do
    ~H"""
    <div
      id={@card.dom_id}
      class="once-schedule-card mt-2 rounded border border-edge px-3 py-2 space-y-1"
    >
      <div class="flex items-center justify-between gap-2">
        <div class="text-sm font-medium">{@card.name}</div>
        <div class="flex items-center gap-2">
          <button
            :if={@card.enabled}
            type="button"
            phx-click={@card.event}
            phx-value-id={@card.id}
            class="text-xs"
          >
            {if(@card.switch == :on, do: gettext("开"), else: gettext("关"))}
          </button>
          <span :if={!@card.enabled and @card.switch} class="text-xs text-secondary">
            {if(@card.switch == :on, do: gettext("开"), else: gettext("关"))}
          </span>
          <button
            :if={@card.id}
            type="button"
            phx-click="schedule_delete"
            phx-value-id={@card.id}
            class="text-xs"
          >
            {gettext("删除")}
          </button>
        </div>
      </div>
      <div id={"#{@card.dom_id}-status"} class="text-xs text-secondary">
        {Enum.join(@card.lines, " · ")}
      </div>
      <p
        :if={@card.countdown_at}
        id={@card.countdown_id}
        phx-hook="ScheduleCountdown"
        data-at={@card.countdown_at}
        data-due-target={"#{@card.dom_id}-status"}
        data-due-lines={Enum.join(@card.due_lines, " · ")}
        class="text-xs"
      >
        {gettext("下次还要")}
      </p>
      <p class="text-xs whitespace-pre-wrap">{@card.instruction}</p>
    </div>
    """
  end

  def once_props(entry, schedules, runs_by_id, _zone) do
    with true <- tool_name(entry) == "schedule",
         true <- tool_action(entry) == "create",
         true <- once_tool?(entry),
         id when is_binary(id) <- schedule_id(entry) do
      schedules = schedules || []

      case Enum.find(schedules, &(&1.id == id)) do
        nil ->
          deleted = Presentation.deleted()

          %{
            dom_id: "once-card-#{entry["id"]}",
            countdown_id: "once-countdown-#{entry["id"]}",
            id: nil,
            name: tool_text(entry, "name", gettext("定时任务")),
            instruction: tool_text(entry, "instruction", ""),
            event: nil,
            countdown_at: nil,
            due_lines: [],
            switch: nil,
            enabled: false,
            lines: deleted.lines
          }

        schedule ->
          runs = Map.get(runs_by_id || %{}, schedule.id, [])

          view =
            Presentation.once(schedule, runs, Handbeam.Schedule.now()) || Presentation.deleted()

          %{
            dom_id: "once-card-#{entry["id"]}",
            countdown_id: "once-countdown-#{entry["id"]}",
            id: schedule.id,
            name: schedule.name,
            instruction: schedule.instruction,
            event: event_name(view.action),
            countdown_at: Map.get(view, :countdown_at),
            due_lines: Map.get(view, :due_lines, []),
            switch: view.switch,
            enabled: view.enabled,
            lines: view.lines
          }
      end
    else
      _ -> nil
    end
  end

  defp dock_cards(schedules, runs, timeline) when is_list(schedules) and is_list(timeline) do
    now = Handbeam.Schedule.now()

    current =
      Enum.flat_map(schedules, fn entry ->
        if Rule.once?(entry.rule) do
          view = Presentation.once(entry, Map.get(runs || %{}, entry.id, []), now)

          [
            %{
              dom_id: "once-dock-#{entry.id}",
              countdown_id: "once-countdown-dock-#{entry.id}",
              id: entry.id,
              name: entry.name,
              instruction: entry.instruction,
              event: event_name(view.action),
              countdown_at: Map.get(view, :countdown_at),
              due_lines: Map.get(view, :due_lines, []),
              switch: view.switch,
              enabled: view.enabled,
              lines: view.lines
            }
          ]
        else
          []
        end
      end)

    deleted =
      timeline
      |> Enum.flat_map(fn entry ->
        case once_props(entry, schedules, runs, nil) do
          %{id: nil} = card -> [card]
          _ -> []
        end
      end)
      |> Enum.uniq_by(& &1.dom_id)

    current ++ deleted
  end

  defp dock_cards(_schedules, _runs, _timeline), do: []

  defp event_name(:pause), do: "schedule_pause"
  defp event_name(:resume), do: "schedule_resume"
  defp event_name(_action), do: nil

  defp tool_name(entry), do: to_string(entry["tool_name"] || "")

  defp tool_action(entry) do
    input = entry["input"] || %{}
    to_string(Handbeam.Utils.SafeMap.get(input, "action") || "")
  end

  defp once_tool?(entry) do
    input = entry["input"] || %{}
    rule = Handbeam.Utils.SafeMap.get(input, "rule") || %{}
    Handbeam.Utils.SafeMap.get_any(rule, ["kind", :kind]) in ["once", :once]
  end

  defp tool_text(entry, key, fallback) do
    value = entry |> Map.get("input", %{}) |> Handbeam.Utils.SafeMap.get(key)
    if is_binary(value) and value != "", do: value, else: fallback
  end

  defp schedule_id(entry) do
    case entry["output"] do
      %{"id" => id} when is_binary(id) ->
        id

      output when is_binary(output) ->
        decoded_schedule_id(output)

      _ ->
        nil
    end
  end

  defp decoded_schedule_id(output) do
    case Handbeam.JSON.decode(output) do
      {:ok, %{"id" => id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp load_once_entries(conversation_id) do
    case Handbeam.ConversationTranscriptStore.list(conversation_id) do
      {:ok, entries} ->
        Enum.filter(entries, fn entry ->
          tool_name(entry) == "schedule" and tool_action(entry) == "create" and
            once_tool?(entry) and is_binary(schedule_id(entry))
        end)

      {:error, _reason} ->
        []
    end
  end

  defp once_view(entry, runs) do
    Presentation.once(entry, runs, Handbeam.Schedule.now())
  end

  defp sidebar_summary(entry, runs) do
    case once_view(entry, Map.get(runs, entry.id, [])) do
      nil -> "#{Rule.describe(entry.rule)} · #{entry.time_zone}"
      view -> Enum.join(view.lines, " · ")
    end
  end

  defp sidebar_status(entry, runs, zone) do
    case once_view(entry, Map.get(runs, entry.id, [])) do
      nil -> "#{gettext("下次")}：#{next_label(entry, zone)} · #{entry.status}"
      view -> view.headline
    end
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

  defp revise_prompt(entry) do
    "把「#{entry.name}」改成："
  end

  defp next_label(%{next_run_at: nil}, _zone), do: "—"

  defp next_label(entry, zone) do
    Rule.format_local(entry.next_run_at, zone || entry.time_zone)
  end

  defp run_label(run, zone) do
    if run.slot_at, do: Rule.format_local(run.slot_at, zone), else: gettext("立即运行")
  end
end

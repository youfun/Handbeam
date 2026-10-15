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
    |> reset()
  end

  def reset(socket) do
    socket
    |> Phoenix.Component.assign(:show_schedules, false)
    |> Phoenix.Component.assign(:schedule_request, "")
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
      |> Phoenix.Component.assign(:schedules, [])
      |> Phoenix.Component.assign(:schedule_runs, %{})
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

  def composer_once_cards(assigns) do
    assigns =
      assign(assigns, :cards, dock_cards(assigns.schedules, assigns.runs))

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
            :if={@card.switch}
            type="button"
            role="switch"
            aria-checked={to_string(@card.switch == :on)}
            aria-label={gettext("定时任务")}
            title={if(@card.switch == :on, do: gettext("暂停"), else: gettext("恢复"))}
            disabled={!@card.enabled}
            phx-click={@card.event}
            phx-value-id={@card.id}
            class="schedule-switch"
          >
            <span class="schedule-switch-thumb" aria-hidden="true"></span>
          </button>
          <button
            :if={@card.id}
            type="button"
            phx-click="schedule_delete"
            phx-value-id={@card.id}
            class="schedule-delete"
            aria-label={gettext("Delete")}
            title={gettext("Delete")}
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              aria-hidden="true"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="M4 7h16M10 11v6m4-6v6M6 7l1 13h10l1-13M9 7V4h6v3"
              />
            </svg>
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

  defp dock_cards(schedules, runs) when is_list(schedules) do
    now = Handbeam.Schedule.now()

    current =
      Enum.flat_map(schedules, fn entry ->
        if Rule.once?(entry.rule) do
          view = Presentation.once(entry, Map.get(runs || %{}, entry.id, []), now)

          if view.enabled do
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
        else
          []
        end
      end)

    current
  end

  defp dock_cards(_schedules, _runs), do: []

  defp event_name(:pause), do: "schedule_pause"
  defp event_name(:resume), do: "schedule_resume"

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

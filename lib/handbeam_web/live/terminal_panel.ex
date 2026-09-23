defmodule HandbeamWeb.Live.TerminalPanel do
  @moduledoc """
  Terminal panel LiveView component.

  Manages terminal sessions for the current workspace.
  Shows terminal tabs with activity indicators, active terminal view,
  create/close/restart controls, and preset command buttons.
  Uses Ghostty.LiveTerminal.Component for terminal rendering.
  """

  use HandbeamWeb, :live_component

  alias Handbeam.Terminal.{Supervisor, Registry}

  @session_call_timeout 2_000

  @preset_commands [
    %{label: "mix phx.server", name: "dev-server", cmd: "mix", args: "phx.server"},
    %{label: "mix test", name: "tests", cmd: "mix", args: "test"},
    %{label: "mix compile", name: "compile", cmd: "mix", args: "compile"},
    %{label: "iex -S mix", name: "iex", cmd: "iex", args: "-S mix"},
    %{label: "npm run dev", name: "npm-dev", cmd: "npm", args: "run dev"},
    %{label: "git log", name: "git-log", cmd: "git", args: "log --oneline"}
  ]

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    workspace_id = assigns.workspace_id

    # Extract forwarded action before passing all assigns to the socket
    {action, clean_assigns} = Map.pop(assigns, :action)

    socket =
      socket
      |> assign(clean_assigns)
      |> assign(:show_create_form, false)
      |> assign(:new_terminal_name, "")
      |> assign(:new_terminal_cmd, "")
      |> assign(:new_terminal_args, "")
      |> assign(:create_error, nil)
      |> assign(:confirm_close, nil)
      |> assign(:restart_target, nil)
      |> assign(:active_terminal_name, socket.assigns[:active_terminal_name])
      |> assign(:activity, socket.assigns[:activity] || %{})
      |> assign(:preset_commands, @preset_commands)
      |> assign_terminals(workspace_id)

    # Handle forwarded PubSub actions from WorkspaceLive
    socket = handle_action(action, socket)

    if connected?(socket) do
      # Subscriptions handled by parent WorkspaceLive;
      # LiveComponents share the parent process.
    end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="terminal-panel flex flex-col h-full bg-main">
      <!-- Terminal tabs bar -->
      <div class="flex items-center border-b bg-surface px-2 h-9 gap-1">
        <div class="flex items-center overflow-x-auto flex-1 gap-0.5">
          <button
            :for={t <- @terminals}
            phx-click="select_terminal"
            phx-value-name={t.name}
            phx-target={@myself}
            class={[
              "terminal-tab",
              if(@active_terminal_name == t.name, do: "active", else: "")
            ]}
          >
            <span class={["status-dot", t.status]}></span>
            <span
              :if={show_activity?(@activity, t.name, @active_terminal_name)}
              class="activity-dot"
            ></span>
            <span class="truncate max-w-[120px]">{t.name}</span>
          </button>
          <div :if={@terminals == []} class="px-3 py-1 text-xs text-tertiary italic">
            no terminals
          </div>
        </div>

        <div class="flex items-center gap-1 flex-shrink-0">
          <button
            :if={@active_terminal_name && terminal_exited?(@terminals, @active_terminal_name)}
            phx-click="restart_terminal"
            phx-target={@myself}
            class="terminal-action-btn text-yellow-500"
            title="Restart terminal"
          >
            ↻
          </button>
          <button
            phx-click="toggle_create_form"
            phx-target={@myself}
            class="terminal-action-btn"
            title="New terminal"
          >
            +
          </button>
          <button
            :if={@active_terminal_name}
            phx-click="confirm_close_terminal"
            phx-target={@myself}
            class="terminal-action-btn text-error"
            title="Close terminal"
          >
            ×
          </button>
        </div>
      </div>

      <!-- Create terminal form -->
      <div :if={@show_create_form} class="border-b bg-surface p-3 space-y-2">
        <!-- Preset quick-start buttons -->
        <div class="flex flex-wrap gap-1">
          <button
            :for={preset <- @preset_commands}
            phx-click="apply_preset"
            phx-value-label={preset.label}
            phx-value-name={preset.name}
            phx-value-cmd={preset.cmd}
            phx-value-args={preset.args}
            phx-target={@myself}
            class="text-[10px] px-2 py-0.5 rounded bg-main border text-tertiary hover:text-primary hover:border-accent transition-colors"
          >
            {preset.label}
          </button>
        </div>

        <div class="flex gap-2">
          <input
            type="text"
            name="term_name"
            value={@new_terminal_name}
            placeholder="name (e.g. dev-server)"
            phx-keyup="update_create_field"
            phx-value-field="name"
            phx-target={@myself}
            class="flex-1 bg-main border rounded px-2 py-1 text-xs text-primary focus:outline-none focus:border-accent"
          />
          <input
            type="text"
            name="term_cmd"
            value={@new_terminal_cmd}
            placeholder="command (e.g. mix phx.server)"
            phx-keyup="update_create_field"
            phx-value-field="cmd"
            phx-target={@myself}
            class="flex-1 bg-main border rounded px-2 py-1 text-xs text-primary font-mono focus:outline-none focus:border-accent"
          />
        </div>
        <div class="flex gap-2 items-center">
          <input
            type="text"
            name="term_args"
            value={@new_terminal_args}
            placeholder="args (space-separated)"
            phx-keyup="update_create_field"
            phx-value-field="args"
            phx-target={@myself}
            class="flex-1 bg-main border rounded px-2 py-1 text-xs text-primary font-mono focus:outline-none focus:border-accent"
          />
          <button
            phx-click="create_terminal"
            phx-target={@myself}
            class="bg-accent text-white text-xs px-3 py-1 rounded hover:opacity-90 transition-opacity"
          >
            Create
          </button>
          <button
            phx-click="toggle_create_form"
            phx-target={@myself}
            class="text-xs text-tertiary hover:text-primary px-2 py-1"
          >
            Cancel
          </button>
        </div>
        <div :if={@create_error} class="text-xs text-error">{@create_error}</div>
      </div>

      <!-- Confirm close dialog -->
      <div :if={@confirm_close} class="border-b bg-surface p-3">
        <p class="text-xs text-primary mb-2">
          Close terminal "<span class="font-semibold">{@confirm_close}</span>"?
          Any running process will be terminated.
        </p>
        <div class="flex gap-2">
          <button
            phx-click="close_terminal"
            phx-target={@myself}
            class="bg-error text-white text-xs px-3 py-1 rounded"
          >
            Close
          </button>
          <button
            phx-click="cancel_close"
            phx-target={@myself}
            class="text-xs text-tertiary hover:text-primary px-2 py-1"
          >
            Cancel
          </button>
        </div>
      </div>

      <!-- Confirm restart dialog -->
      <div :if={@restart_target} class="border-b bg-surface p-3">
        <p class="text-xs text-primary mb-2">
          Restart terminal "<span class="font-semibold">{@restart_target}</span>"?
        </p>
        <div class="flex gap-2">
          <button
            phx-click="do_restart_terminal"
            phx-target={@myself}
            class="bg-accent text-white text-xs px-3 py-1 rounded"
          >
            Restart
          </button>
          <button
            phx-click="cancel_restart"
            phx-target={@myself}
            class="text-xs text-tertiary hover:text-primary px-2 py-1"
          >
            Cancel
          </button>
        </div>
      </div>

      <!-- Active terminal view -->
      <div class="flex-1 overflow-hidden">
        <%= if @active_terminal_name && @active_term_pid && @active_pty_pid do %>
          <.live_component
            module={Ghostty.LiveTerminal.Component}
            id={"term-#{@active_terminal_name}"}
            term={@active_term_pid}
            pty={@active_pty_pid}
            fit={true}
            autofocus={true}
          />
        <% else %>
          <div class="flex items-center justify-center h-full text-tertiary text-xs">
            <div :if={@terminals == []} class="text-center space-y-2">
              <div class="text-2xl opacity-30">▸_</div>
              <p>No terminals. Create one to run commands.</p>
              <button
                phx-click="toggle_create_form"
                phx-target={@myself}
                class="text-accent hover:underline text-xs mt-2"
              >
                + New Terminal
              </button>
            </div>
            <div :if={@terminals != [] && !@active_terminal_name} class="text-center space-y-2">
              <div class="text-2xl opacity-30">▸_</div>
              <p>Select a terminal to view its output.</p>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Event handlers ──

  @impl true
  def handle_event("select_terminal", %{"name" => name}, socket) do
    socket =
      socket
      |> activate_terminal(name)
      |> clear_activity(name)

    {:noreply, socket}
  end

  def handle_event("toggle_create_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_form, !socket.assigns.show_create_form)
     |> assign(:create_error, nil)}
  end

  def handle_event("apply_preset", params, socket) do
    {:noreply,
     socket
     |> assign(:new_terminal_name, params["name"] || "")
     |> assign(:new_terminal_cmd, params["cmd"] || "")
     |> assign(:new_terminal_args, params["args"] || "")
     |> assign(:create_error, nil)}
  end

  def handle_event("update_create_field", %{"field" => field} = params, socket) do
    value = params["value"] || ""

    socket =
      case field do
        "name" -> assign(socket, :new_terminal_name, value)
        "cmd" -> assign(socket, :new_terminal_cmd, value)
        "args" -> assign(socket, :new_terminal_args, value)
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("create_terminal", _params, socket) do
    name = String.trim(socket.assigns.new_terminal_name)
    cmd = String.trim(socket.assigns.new_terminal_cmd)
    args_str = String.trim(socket.assigns.new_terminal_args)

    cond do
      name == "" ->
        {:noreply, assign(socket, :create_error, "Name is required")}

      cmd == "" ->
        {:noreply, assign(socket, :create_error, "Command is required")}

      true ->
        args = if args_str == "", do: [], else: String.split(args_str, ~r/\s+/)
        workspace_id = socket.assigns.workspace_id
        workspace_path = socket.assigns.workspace_path

        case Supervisor.start_terminal(workspace_id, name,
               cmd: cmd,
               args: args,
               workspace_path: workspace_path
             ) do
          {:ok, _pid} ->
            socket =
              socket
              |> assign(:show_create_form, false)
              |> assign(:new_terminal_name, "")
              |> assign(:new_terminal_cmd, "")
              |> assign(:new_terminal_args, "")
              |> assign(:create_error, nil)
              |> assign_terminals(workspace_id)
              |> activate_terminal(name)
              |> clear_activity(name)

            {:noreply, socket}

          {:error, :already_exists} ->
            {:noreply, assign(socket, :create_error, "Terminal '#{name}' already exists")}

          {:error, reason} ->
            {:noreply, assign(socket, :create_error, "Failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("confirm_close_terminal", _params, socket) do
    {:noreply, assign(socket, :confirm_close, socket.assigns.active_terminal_name)}
  end

  def handle_event("cancel_close", _params, socket) do
    {:noreply, assign(socket, :confirm_close, nil)}
  end

  def handle_event("close_terminal", _params, socket) do
    name = socket.assigns.confirm_close
    workspace_id = socket.assigns.workspace_id

    Supervisor.stop_terminal(workspace_id, name)

    socket =
      socket
      |> assign(:confirm_close, nil)
      |> assign_terminals(workspace_id)

    socket =
      if socket.assigns.active_terminal_name == name do
        next = List.first(socket.assigns.terminals)
        activate_terminal(socket, (next && next.name) || nil)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("restart_terminal", _params, socket) do
    {:noreply, assign(socket, :restart_target, socket.assigns.active_terminal_name)}
  end

  def handle_event("cancel_restart", _params, socket) do
    {:noreply, assign(socket, :restart_target, nil)}
  end

  def handle_event("do_restart_terminal", _params, socket) do
    name = socket.assigns.restart_target
    workspace_id = socket.assigns.workspace_id

    # Close old session first
    Supervisor.stop_terminal(workspace_id, name)

    # Get the original command from the current terminal list
    old = Enum.find(socket.assigns.terminals, &(&1.name == name))

    opts =
      if old do
        [cmd: old.cmd, args: old.args, workspace_path: socket.assigns.workspace_path]
      else
        [workspace_path: socket.assigns.workspace_path]
      end

    case Supervisor.start_terminal(workspace_id, name, opts) do
      {:ok, _pid} ->
        socket =
          socket
          |> assign(:restart_target, nil)
          |> assign_terminals(workspace_id)
          |> activate_terminal(name)
          |> clear_activity(name)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:restart_target, nil)
         |> assign(:create_error, "Restart failed: #{inspect(reason)}")}
    end
  end

  # ── PubSub forwarding (received via send_update from WorkspaceLive) ──

  defp handle_action({:terminal_refresh, term_name}, socket) do
    socket =
      socket
      |> assign_terminals(socket.assigns.workspace_id)
      |> mark_activity(term_name)

    if socket.assigns.active_terminal_name == term_name do
      send_update(Ghostty.LiveTerminal.Component,
        id: "term-#{term_name}",
        refresh: true
      )
    end

    socket
  end

  defp handle_action({:terminal_exited, _term_name, _status}, socket) do
    assign_terminals(socket, socket.assigns.workspace_id)
  end

  defp handle_action(nil, socket), do: socket

  # ── Helpers ──

  defp assign_terminals(socket, workspace_id) do
    terminals = Supervisor.list_terminals(workspace_id)
    assign(socket, :terminals, terminals)
  end

  defp activate_terminal(socket, nil) do
    socket
    |> assign(:active_terminal_name, nil)
    |> assign(:active_term_pid, nil)
    |> assign(:active_pty_pid, nil)
  end

  defp activate_terminal(socket, name) do
    workspace_id = socket.assigns.workspace_id

    case Registry.lookup(workspace_id, name) do
      {:ok, session_pid} ->
        case safe_session_info(session_pid) do
          {:ok, info} ->
            socket
            |> assign(:active_terminal_name, name)
            |> assign(:active_term_pid, info.term)
            |> assign(:active_pty_pid, info.pty)

          {:error, _reason} ->
            socket
            |> assign(:active_terminal_name, name)
            |> assign(:active_term_pid, nil)
            |> assign(:active_pty_pid, nil)
        end

      {:error, :not_found} ->
        socket
        |> assign(:active_terminal_name, nil)
        |> assign(:active_term_pid, nil)
        |> assign(:active_pty_pid, nil)
    end
  end

  defp safe_session_info(pid) do
    try do
      info = GenServer.call(pid, :info, @session_call_timeout)
      {:ok, info}
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, _ -> {:error, :dead}
    end
  end

  defp mark_activity(socket, term_name) do
    activity = Map.put(socket.assigns.activity, term_name, true)
    assign(socket, :activity, activity)
  end

  defp clear_activity(socket, term_name) do
    activity = Map.put(socket.assigns.activity, term_name, false)
    assign(socket, :activity, activity)
  end

  defp show_activity?(activity, term_name, active_name) do
    term_name != active_name && Map.get(activity, term_name, false)
  end

  defp terminal_exited?(terminals, name) do
    Enum.any?(terminals, &(&1.name == name && &1.status == :exited))
  end
end

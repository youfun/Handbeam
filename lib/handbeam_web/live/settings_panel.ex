defmodule HandbeamWeb.Live.SettingsPanel do
  @moduledoc """
  Desktop Settings panel shell — modal overlay with left menu + right form area.

  Concrete settings forms live in dedicated panel modules.
  """

  use HandbeamWeb, :live_component

  alias Handbeam.Settings
  alias Handbeam.Settings.ModelAISettings
  alias HandbeamWeb.Live.Settings.ModelAIPanel

  @menu_items [
    %{id: :model_ai, label_key: "Model / AI"},
    %{id: :sns, label_key: "SNS"},
    %{id: :tools, label_key: "Tools"},
    %{id: :security, label_key: "Security"},
    %{id: :ui, label_key: "UI"}
  ]

  @impl true
  def update(%{open: false}, socket), do: {:ok, assign(socket, :open, false)}

  def update(assigns, socket) do
    was_open = Map.get(socket.assigns, :open, false)
    now_open = Map.get(assigns, :open, false)

    socket =
      socket
      |> assign(assigns)
      |> assign(:menu, :model_ai)
      |> assign(:menu_items, @menu_items)
      |> assign(:errors, %{})
      |> assign(:saving, false)

    # Fix #2: Only load form from disk on first open, not on re-renders.
    # Fix #3: Remember last scope to avoid always defaulting to global.
    socket =
      if not was_open and now_open do
        last_scope_type = Map.get(socket.assigns, :last_scope_type, :global)

        scope =
          if last_scope_type == :workspace do
            {:workspace, socket.assigns.workspace_id}
          else
            :global
          end

        load_scope(socket, scope)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="settings-panel-root">
      <div
        :if={@open}
        id="settings-overlay"
        class="settings-overlay"
      >
        <div
          id="settings-backdrop"
          class="absolute inset-0 z-0"
          phx-click="close_settings"
          phx-target={@myself}
        >
        </div>
        <div
          id="settings-panel"
          class="settings-modal bg-surface border rounded-xl shadow-2xl flex overflow-hidden relative z-10"
        >
          <div class="settings-menu bg-main border-r py-3">
            <div class="px-3 mb-2 projects-panel-title">
              {gettext("Settings")}
            </div>
            <button
              :for={item <- @menu_items}
              phx-click="select_menu"
              phx-value-menu={item.id}
              phx-target={@myself}
              class={[
                "w-full text-left px-4 py-2 text-sm transition-colors",
                if(@menu == item.id,
                  do: "bg-surface-active text-accent font-medium",
                  else: "text-secondary hover:bg-surface-hover"
                )
              ]}
            >
              {menu_label(item.id)}
            </button>
          </div>

          <div class="flex-1 flex flex-col min-w-0">
            <div class="flex items-center justify-between px-4 py-3 border-b">
              <div class="flex items-center gap-3">
                <h3 class="text-sm font-semibold text-primary">
                  {menu_label(@menu)}
                </h3>
                <.scope_selector scope={@scope} workspace_label={@workspace_label} target={@myself} />
              </div>
              <button
                phx-click="close_settings"
                phx-target={@myself}
                class="p-2 rounded text-tertiary hover:bg-surface-hover"
                aria-label={gettext("Close")}
              >
                <svg
                  width="18"
                  height="18"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                >
                  <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
                </svg>
              </button>
            </div>

            <div class="flex-1 overflow-y-auto p-5">
              <%= if @menu == :model_ai do %>
                <ModelAIPanel.render
                  form={@form}
                  available_models={@available_models}
                  errors={@errors}
                  target={@myself}
                  scope={@scope}
                />
              <% else %>
                <div class="settings-card">
                  <div class="settings-field-row is-disabled">
                    <div class="settings-field-copy">
                      <div class="settings-field-title">
                        {menu_label(@menu)}
                        <span class="settings-badge-experimental">{gettext("Experimental")}</span>
                      </div>
                      <div class="settings-field-desc">
                        {gettext("%{name} settings — coming soon", name: menu_label(@menu))}
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>

            <div
              :if={@menu == :model_ai}
              class="flex items-center justify-end gap-2 px-4 py-3 border-t bg-main"
            >
              <button
                phx-click="close_settings"
                phx-target={@myself}
                class="px-4 py-1.5 text-sm text-secondary hover:bg-surface-hover rounded"
              >
                {gettext("Cancel")}
              </button>
              <button
                phx-click="save_settings"
                phx-target={@myself}
                disabled={@saving}
                class="px-4 py-1.5 text-sm bg-user text-white rounded hover:bg-user-hover"
              >
                {if @saving, do: gettext("Saving..."), else: gettext("Save")}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("close_settings", _, socket) do
    send(self(), :settings_closed)
    {:noreply, assign(socket, :open, false)}
  end

  def handle_event("select_menu", %{"menu" => menu_id}, socket) do
    menu = menu_from_id(menu_id) || socket.assigns.menu
    {:noreply, assign(socket, :menu, menu)}
  end

  def handle_event("select_scope", %{"scope" => scope_str}, socket) do
    scope =
      if scope_str == "workspace", do: {:workspace, socket.assigns.workspace_id}, else: :global

    scope_type = if scope_str == "workspace", do: :workspace, else: :global

    {:noreply,
     socket
     |> load_scope(scope)
     |> assign(:last_scope_type, scope_type)}
  end

  def handle_event("update_field", params, socket) do
    # params: %{"field_name" => "value"} from form phx-change, or %{"field" => f, "value" => v} from legacy
    {field, value} =
      if Map.has_key?(params, "field") do
        {params["field"], params["value"]}
      else
        field =
          params
          |> Enum.find(fn {k, _v} -> k not in ["_target", "__changed__"] end)
          |> elem(0)

        field = field || ""
        {field, Map.get(params, field, "")}
      end

    form = update_form_field(socket.assigns.form, field, value)
    errors = validate_form(form)
    {:noreply, socket |> assign(:form, form) |> assign(:errors, errors)}
  end

  def handle_event("save_settings", _, socket) do
    form = socket.assigns.form
    errors = validate_form(form)

    if errors == %{} do
      socket = assign(socket, :saving, true)

      case save_current_scope(socket, form) do
        :ok ->
          case Settings.fetch_effective_model_ai(socket.assigns.workspace_path) do
            {:ok, effective} ->
              send(self(), {:settings_saved, effective})
              {:noreply, socket |> assign(:saving, false) |> assign(:open, false)}

            {:error, reason} ->
              {:noreply,
               socket
               |> assign(:saving, false)
               |> assign(:errors, %{general: format_error(reason)})}
          end

        {:error, reason} ->
          {:noreply,
           socket |> assign(:saving, false) |> assign(:errors, %{general: format_error(reason)})}
      end
    else
      {:noreply, assign(socket, :errors, errors)}
    end
  end

  # Fix #1: Skip save when diff is empty to prevent wiping existing settings
  # with an empty {"model_ai": {}} write.
  defp save_current_scope(%{assigns: %{scope: :global}} = _socket, form) do
    defaults = ModelAISettings.defaults()
    diff = ModelAISettings.diff(defaults, form)

    if diff == %{} do
      :ok
    else
      diff
      |> ModelAISettings.override_to_json_map()
      |> Settings.save_global()
    end
  end

  defp save_current_scope(
         %{assigns: %{scope: {:workspace, _}, workspace_path: workspace_path}} = _socket,
         form
       ) do
    base = Settings.global_model_ai()
    diff = ModelAISettings.diff(base, form)

    if diff == %{} do
      :ok
    else
      map =
        diff
        |> ModelAISettings.override_to_json_map()

      Settings.save_workspace_model_ai(workspace_path, map)
    end
  end

  defp load_scope(socket, :global) do
    {:ok, global} = Settings.load_global()
    form = ModelAISettings.new(Map.get(global, "model_ai", %{}))

    socket
    |> assign(:scope, :global)
    |> assign(:form, form)
  end

  defp load_scope(socket, {:workspace, _ws_id} = scope) do
    workspace_path = socket.assigns.workspace_path

    form =
      case Settings.fetch_effective_model_ai(workspace_path) do
        {:ok, effective} -> effective
        {:error, _reason} -> Settings.global_model_ai()
      end

    socket
    |> assign(:scope, scope)
    |> assign(:form, form)
  end

  defp update_form_field(form, field, value) do
    case field do
      "om_enabled" -> struct!(form, om_enabled: value in [true, "true"])
      "default_model" -> struct!(form, default_model: blank_to_nil(value))
      "reasoning" -> struct!(form, reasoning: value)
      "om_observer_model" -> struct!(form, om_observer_model: blank_to_nil(value))
      "om_reflector_model" -> struct!(form, om_reflector_model: blank_to_nil(value))
      "om_memory_scope" -> struct!(form, om_memory_scope: value)
      "om_privacy_mode" -> struct!(form, om_privacy_mode: value)
      "om_max_recent_context" -> struct!(form, om_max_recent_context: parse_int(value, 5))
      "om_message_tokens" -> struct!(form, om_message_tokens: parse_int(value, 30_000))
      "om_buffer_tokens" -> struct!(form, om_buffer_tokens: parse_int(value, 10_000))
      "om_observation_tokens" -> struct!(form, om_observation_tokens: parse_int(value, 40_000))
      _ -> form
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp parse_int(v, _default) when is_integer(v), do: v

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp validate_form(form) do
    map = %{
      om_privacy_mode: form.om_privacy_mode,
      om_memory_scope: form.om_memory_scope,
      om_max_recent_context: form.om_max_recent_context,
      om_message_tokens: form.om_message_tokens,
      om_buffer_tokens: form.om_buffer_tokens,
      om_observation_tokens: form.om_observation_tokens
    }

    case ModelAISettings.validate(map) do
      :ok -> %{}
      {:error, reason} -> %{general: reason}
    end
  end

  def scope_selector(assigns) do
    ~H"""
    <div class="flex bg-main border rounded-lg text-xs gap-1.5" style="padding: 2px;">
      <button
        phx-click="select_scope"
        phx-value-scope="global"
        phx-target={@target}
        class={[
          "px-2 py-1 rounded transition-colors text-xs",
          if(@scope == :global,
            do: "bg-surface text-primary font-medium",
            else: "text-tertiary hover:bg-surface-hover"
          )
        ]}
      >
        {gettext("Global")}
      </button>
      <button
        phx-click="select_scope"
        phx-value-scope="workspace"
        phx-target={@target}
        class={[
          "px-2 py-1 rounded transition-colors text-xs truncate settings-scope-workspace",
          if(match?({:workspace, _}, @scope),
            do: "bg-surface text-primary font-medium",
            else: "text-tertiary hover:bg-surface-hover"
          )
        ]}
      >
        <span class="truncate">{@workspace_label}</span>
      </button>
    </div>
    """
  end

  defp menu_from_id(menu_id) when is_binary(menu_id) do
    Enum.find_value(@menu_items, fn item -> if Atom.to_string(item.id) == menu_id, do: item.id end)
  end

  defp menu_label(:model_ai), do: gettext("Model / AI")
  defp menu_label(:sns), do: gettext("SNS")
  defp menu_label(:tools), do: gettext("Tools")
  defp menu_label(:security), do: gettext("Security")
  defp menu_label(:ui), do: gettext("UI")
  defp menu_label(_), do: gettext("Settings")

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end

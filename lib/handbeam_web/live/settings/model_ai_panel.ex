defmodule HandbeamWeb.Live.Settings.ModelAIPanel do
  @moduledoc """
  Model / AI settings panel content.

  Kept separate from the Settings shell so future settings sections do not
  accumulate in one large LiveView/HEEx module.
  """

  use HandbeamWeb, :html

  attr(:form, :map, required: true)
  attr(:available_models, :list, required: true)
  attr(:errors, :map, required: true)
  attr(:target, :any, default: nil)
  attr(:scope, :any, default: :global)

  def render(assigns) do
    target_attrs = if assigns.target, do: %{:"phx-target" => assigns.target}, else: %{}
    assigns = assign(assigns, :target_attrs, target_attrs)

    ~H"""
    <form {@target_attrs} class="settings-model-ai-form">
      <section class="settings-model-section">
        <div class="settings-model-section-header">
          <h4 class="settings-model-section-title">
            {gettext("Model")}
          </h4>
          <span
            :if={@scope != :global}
            class="text-xs text-warning bg-warning-subtle px-2 py-1 rounded"
          >
            {gettext("workspace override")}
          </span>
        </div>
        <div class="settings-card">
          <div class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Default model")}</div>
              <div class="settings-field-desc">
                {gettext("Used for new conversations unless a workspace default overrides it.")}
              </div>
            </div>
            <div class="settings-field-control">
              <select
                name="default_model"
                phx-change="update_field"
                class="settings-input"
              >
                <option value="" selected={is_nil(@form.default_model)}>
                  {gettext("None (use provider default)")}
                </option>
                <option
                  :for={m <- @available_models}
                  value={model_value(m)}
                  selected={@form.default_model == model_value(m)}
                >
                  {model_display(m)}
                </option>
              </select>
            </div>
          </div>
          <div class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Reasoning")}</div>
              <div class="settings-field-desc">
                {gettext("How much internal reasoning the model should use.")}
              </div>
            </div>
            <div class="settings-field-control">
              <select
                name="reasoning"
                phx-change="update_field"
                class="settings-input"
              >
                <option value="off" selected={@form.reasoning == "off"}>{gettext("Off")}</option>
                <option value="minimal" selected={@form.reasoning == "minimal"}>
                  {gettext("Minimal")}
                </option>
                <option value="low" selected={@form.reasoning == "low"}>{gettext("Low")}</option>
                <option value="medium" selected={@form.reasoning == "medium"}>
                  {gettext("Medium")}
                </option>
                <option value="high" selected={@form.reasoning == "high"}>{gettext("High")}</option>
                <option value="xhigh" selected={@form.reasoning == "xhigh"}>
                  {gettext("X-High")}
                </option>
              </select>
            </div>
          </div>
        </div>
      </section>

      <section class="settings-model-section">
        <h4 class="settings-model-section-title">
          {gettext("Observational Memory")}
        </h4>
        <div class="settings-card">
          <div class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Observational Memory")}</div>
              <div class="settings-field-desc">
                {gettext("Watch conversations and extract durable memories.")}
              </div>
            </div>
            <div class="settings-field-control">
              <label class="relative inline-flex items-center cursor-pointer h-4">
                <input
                  type="checkbox"
                  name="om_enabled"
                  phx-change="update_field"
                  checked={@form.om_enabled}
                  class="sr-only peer"
                />
                <span class="settings-toggle-track">
                  <span class="settings-toggle-thumb"></span>
                </span>
              </label>
            </div>
          </div>

          <div :if={@form.om_enabled} class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Observer model")}</div>
              <div class="settings-field-desc">
                {gettext("Model that watches the conversation.")}
              </div>
            </div>
            <div class="settings-field-control">
              <select
                name="om_observer_model"
                phx-change="update_field"
                class="settings-input"
              >
                <option
                  value=""
                  selected={is_nil(@form.om_observer_model)}
                >
                  {gettext("Same as default model")}
                </option>
                <option
                  :for={m <- @available_models}
                  value={model_value(m)}
                  selected={@form.om_observer_model == model_value(m)}
                >
                  {model_display(m)}
                </option>
              </select>
            </div>
          </div>
          <div :if={@form.om_enabled} class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Reflector model")}</div>
              <div class="settings-field-desc">
                {gettext("Model that consolidates observed memories.")}
              </div>
            </div>
            <div class="settings-field-control">
              <select
                name="om_reflector_model"
                phx-change="update_field"
                class="settings-input"
              >
                <option value="" selected={is_nil(@form.om_reflector_model)}>
                  {gettext("Same as observer")}
                </option>
                <option
                  :for={m <- @available_models}
                  value={model_value(m)}
                  selected={@form.om_reflector_model == model_value(m)}
                >
                  {model_display(m)}
                </option>
              </select>
            </div>
          </div>

          <div :if={@form.om_enabled} class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Memory scope")}</div>
              <div class="settings-field-desc">
                {gettext("Where extracted memories are stored.")}
              </div>
            </div>
            <div class="settings-field-control">
              <select
                name="om_memory_scope"
                phx-change="update_field"
                class="settings-input"
              >
                <option value="workspace" selected={@form.om_memory_scope == "workspace"}>
                  {gettext("Workspace only")}
                </option>
                <option value="global" selected={@form.om_memory_scope == "global"}>
                  {gettext("Global")}
                </option>
                <option value="both" selected={@form.om_memory_scope == "both"}>
                  {gettext("Both")}
                </option>
              </select>
            </div>
          </div>
          <div :if={@form.om_enabled} class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Privacy mode")}</div>
              <div class="settings-field-desc">
                {gettext("How isolated memory processing should be.")}
              </div>
            </div>
            <div class="settings-field-control">
              <select
                name="om_privacy_mode"
                phx-change="update_field"
                class="settings-input"
              >
                <option value="standard" selected={@form.om_privacy_mode == "standard"}>
                  {gettext("Standard")}
                </option>
                <option value="local_only" selected={@form.om_privacy_mode == "local_only"}>
                  {gettext("Data isolated")}
                </option>
              </select>
            </div>
          </div>

          <div :if={@form.om_enabled} class="settings-field-row">
            <div class="settings-field-copy">
              <div class="settings-field-title">{gettext("Recent context limit")}</div>
              <div class="settings-field-desc">
                {gettext("How many recent turns the observer may read.")}
              </div>
            </div>
            <div class="settings-field-control">
              <input
                type="number"
                name="om_max_recent_context"
                phx-change="update_field"
                value={@form.om_max_recent_context}
                min="0"
                max="20"
                class="settings-input"
              />
            </div>
          </div>
        </div>
      </section>

      <div :if={@errors != %{}} class="bg-error-subtle border rounded-lg p-3 text-sm text-error">
        <p :for={{_k, msg} <- @errors}>{msg}</p>
      </div>
    </form>
    """
  end

  defp model_value(m) when is_map(m) do
    provider = Map.get(m, :provider) || Map.get(m, "provider")
    model = Map.get(m, :model) || Map.get(m, "model")
    provider_id = Map.get(m, :provider_id) || Map.get(m, "provider_id")
    model_id = Map.get(m, :model_id) || Map.get(m, "model_id")
    id = Map.get(m, :id) || Map.get(m, "id")

    cond do
      provider && model -> "#{provider}/#{model}"
      provider_id && model_id -> "#{provider_id}/#{model_id}"
      id -> id
      true -> ""
    end
  end

  defp model_value(str) when is_binary(str), do: str
  defp model_value(_), do: ""

  defp model_display(m) when is_map(m) do
    provider = Map.get(m, :provider) || Map.get(m, "provider")
    model = Map.get(m, :model) || Map.get(m, "model")
    provider_id = Map.get(m, :provider_id) || Map.get(m, "provider_id")
    model_id = Map.get(m, :model_id) || Map.get(m, "model_id")
    id = Map.get(m, :id) || Map.get(m, "id")
    name = Map.get(m, :name) || Map.get(m, "name")

    cond do
      provider && model -> "#{provider} / #{model}"
      provider_id && (name || model_id) -> "#{provider_id} / #{name || model_id}"
      id -> name || id
      true -> ""
    end
  end

  defp model_display(str) when is_binary(str), do: str
  defp model_display(_), do: ""
end

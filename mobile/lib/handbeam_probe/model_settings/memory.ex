defmodule HandbeamProbe.ModelSettings.Memory do
  @moduledoc """
  Observational memory fields of the Model/AI form (switch, observer/reflector
  models, scope, privacy, recent-context limit). Saves through
  `HandbeamProbe.ModelSettings.Defaults`, so scope rules apply unchanged.
  """

  use Gettext, backend: HandbeamProbe.Gettext
  alias HandbeamProbe.ModelSettings.Defaults
  alias HandbeamProbe.SettingsSupport

  def toggle_enabled(state, workspace) do
    Defaults.save_field(state, workspace, :om_enabled, not state.defaults.om_enabled)
  end

  def set_observer(state, model, workspace) do
    Defaults.save_field(state, workspace, :om_observer_model, Defaults.blank_to_nil(model))
  end

  def set_reflector(state, model, workspace) do
    Defaults.save_field(state, workspace, :om_reflector_model, Defaults.blank_to_nil(model))
  end

  def set_scope(state, scope, workspace) do
    Defaults.save_field(state, workspace, :om_memory_scope, scope)
  end

  def set_privacy(state, mode, workspace) do
    Defaults.save_field(state, workspace, :om_privacy_mode, mode)
  end

  @doc "Validate the recent-context limit typed into the form, then save the form."
  def save_details(state, workspace) do
    case SettingsSupport.parse_non_negative(to_string(state.defaults.om_max_recent_context)) do
      {:ok, :omit} ->
        Defaults.save_form(state, workspace, state.defaults)

      {:ok, n} ->
        Defaults.save_form(state, workspace, %{state.defaults | om_max_recent_context: n})

      {:error, _} ->
        %{state | notice: gettext("Recent context limit must be zero or a positive integer")}
    end
  end
end

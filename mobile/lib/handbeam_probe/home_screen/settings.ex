defmodule HandbeamProbe.HomeScreen.Settings do
  @moduledoc """
  Model / AI settings as seen by the screen.

  Reading the effective settings (`ModelSettings.load/2`) and scanning model
  references before a delete (`ModelSettings.find_refs_async/4`) run under
  `HandbeamProbe.TaskSupervisor`; their task refs are registered under the
  `:models` scope of `HandbeamProbe.PendingRequests` (`HomeScreen.Requests`),
  so a stale reply is dropped before it reaches this module, and a loaded
  result is also dropped when an unsaved form is open. Everything else is a
  pure `ModelSettings.action/3` reduction.
  """

  import Mob.Socket, only: [assign: 3]

  alias HandbeamProbe.HomeScreen.Requests
  alias HandbeamProbe.ModelSettings

  @scope :models

  @settings_pages [:models, :settings]

  # ── dispatch ──

  def handle({:tap, {:composer_setting, field, value}}, socket)
      when field in [:default_model, :reasoning] do
    workspace = socket.assigns.workspace

    models =
      socket.assigns.models
      |> ModelSettings.Defaults.set_scope(:workspace, workspace)
      |> then(&ModelSettings.action({field, value}, &1, workspace))

    socket
    |> assign(:models, models)
    |> assign(:composer_select, nil)
    |> HandbeamProbe.HomeScreen.Notice.put_info(models.notice)
    |> HandbeamProbe.NativeModelInputs.check()
  end

  def handle({:change, {:model_field, field}, value}, socket) do
    assign(socket, :models, ModelSettings.change(socket.assigns.models, field, value))
  end

  def handle({:change, {:toggle_model_enabled, provider, model, _current}, enabled}, socket)
      when is_boolean(enabled) do
    action(socket, {:toggle_model_enabled, provider, model, enabled})
  end

  def handle({:dismiss, :cancel_confirm}, socket), do: action(socket, :cancel_confirm)

  def handle({:tap, {:ask_delete_model, provider, model}}, socket),
    do: find_refs(socket, :delete_model, provider, model)

  def handle({:tap, {:ask_delete_provider, provider}}, socket),
    do: find_refs(socket, :delete_provider, provider, nil)

  def handle({:tap, action}, socket), do: action(socket, action)

  def handle({:models_updated}, socket) do
    # Do not replace an unsaved form when another entry point updates models.
    if socket.assigns.models.form or is_nil(socket.assigns.workspace),
      do: socket,
      else: load_models(socket)
  end

  def settings_page?(page), do: page in @settings_pages

  # ── async ──

  @doc "Reload effective model settings off-screen for the current workspace."
  def load_models(%{assigns: %{workspace: nil}} = socket), do: socket

  def load_models(socket) do
    {generation, socket} = Requests.bump(socket, @scope)
    task = ModelSettings.load_async(socket.assigns.workspace, socket.assigns.models, generation)

    Requests.register(socket, task.ref, :model_settings_loaded,
      scope: @scope,
      generation: generation
    )
  end

  # A form opened while loading owns the state; keep what the user is editing.
  def handle_loaded(socket, models) do
    if socket.assigns.models.form,
      do: socket,
      else: socket |> assign(:models, models) |> HandbeamProbe.NativeModelInputs.check()
  end

  def handle_refs(socket, {kind, provider, model}, result),
    do: action(socket, {:delete_refs_ready, kind, provider, model, result})

  defp find_refs(socket, kind, provider, model) do
    generation = Requests.generation(socket, @scope)
    task = ModelSettings.find_refs_async(kind, provider, model, generation)

    Requests.register(socket, task.ref, :model_settings_refs,
      scope: @scope,
      generation: generation
    )
  end

  defp action(socket, action) do
    models = ModelSettings.action(action, socket.assigns.models, socket.assigns.workspace)
    models = close_select(models, action)

    socket
    |> assign(:models, models)
    |> HandbeamProbe.NativeModelInputs.check()
  end

  defp close_select(models, {:toggle_select, _}), do: models
  defp close_select(models, {:toggle_help, _}), do: models
  defp close_select(models, _), do: %{models | select_open: nil}
end

defmodule HandbeamWeb.WorkspaceLive.CliSelection do
  @moduledoc """
  Composer choice between Handbeam's own loop and an external CLI loop.

  No CLI selected keeps `ModelSelection` and `Handbeam.Agent.Turn`. A selected
  CLI replaces the model list with that CLI's own models. It never falls back
  to the Handbeam provider catalog.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Handbeam.Agent.CliAgent.Registry
  alias Handbeam.Host

  @handbeam ""

  @doc "Assignable CLI backends. A missing executable is omitted, not installed."
  @spec selectable() :: [%{id: String.t(), available: boolean()}]
  def selectable do
    if Host.shell?() do
      Registry.selectable()
      |> Enum.filter(& &1.available)
      |> Enum.map(&%{id: &1.id})
    else
      []
    end
  end

  @doc "Mount assigns. Handbeam remains selected."
  @spec boot() :: map()
  def boot do
    %{
      available_clis: selectable(),
      selected_cli: nil,
      cli_models_error: nil,
      handbeam_models: nil,
      handbeam_selected_model: nil,
      handbeam_reasoning_level: nil,
      handbeam_reasoning_levels: nil,
      cli_sessions: %{}
    }
  end

  @spec assign_boot(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_boot(socket) do
    assign(socket, boot())
  end

  @doc "Whether this turn's loop owner is a CLI rather than Handbeam."
  @spec cli_selected?(map()) :: boolean()
  def cli_selected?(assigns) when is_map(assigns) do
    is_binary(assigns[:selected_cli]) and assigns[:selected_cli] != ""
  end

  @doc """
  Select Handbeam (`nil` or `\"\"`) or a CLI id.

  Selecting a CLI loads that CLI's models. `:models_unavailable` is shown and
  does not reuse Handbeam's catalog.
  """
  @spec select(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  def select(socket, cli) when cli in [nil, ""] do
    socket
    |> forget_current()
    |> restore_handbeam()
  end

  def select(socket, cli) when is_binary(cli) do
    if Enum.any?(socket.assigns.available_clis, &(&1.id == cli)) do
      socket
      |> forget_current()
      |> remember_handbeam()
      |> assign(:selected_cli, cli)
      |> load_cli_models(cli)
    else
      socket
    end
  end

  @spec select_model(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def select_model(socket, model) when is_binary(model) do
    if cli_selected?(socket.assigns) and
         Enum.any?(socket.assigns.available_models, &(&1.id == model)) do
      entry = Enum.find(socket.assigns.available_models, &(&1.id == model))

      socket
      |> assign(:selected_model, model)
      |> assign_reasoning(entry)
    else
      socket
    end
  end

  @doc "Options for `Handbeam.Agent.CliAgent.Run.turn/2`. Nil when Handbeam owns the turn."
  @spec run_opts(Phoenix.LiveView.Socket.t(), String.t()) :: keyword() | nil
  def run_opts(socket, conversation_id) do
    if cli_selected?(socket.assigns) and is_binary(socket.assigns.selected_model) do
      [
        backend: socket.assigns.selected_cli,
        cwd: workspace_cwd(socket),
        model: socket.assigns.selected_model,
        reasoning_effort: socket.assigns.selected_reasoning_level,
        conversation_id: conversation_id,
        run_id: conversation_id,
        session_id: resumed_session_id(socket, conversation_id)
      ]
    end
  end

  @doc "Form value for the CLI picker. Empty string means Handbeam."
  @spec form_value(String.t() | nil) :: String.t()
  def form_value(nil), do: @handbeam
  def form_value(cli), do: cli

  @doc "Composer copy when a CLI cannot provide its own model list."
  @spec error_message(atom()) :: String.t()
  def error_message(:models_unavailable), do: "This CLI cannot list models."
  def error_message(:empty), do: "This CLI has no selectable models."
  def error_message(_), do: "This CLI cannot list models."

  @doc "Remember a finished CLI session so the next message in this conversation can resume it."
  @spec remember_session(Phoenix.LiveView.Socket.t(), String.t(), String.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def remember_session(socket, conversation_id, backend, session_id)
      when is_binary(conversation_id) and is_binary(backend) and is_binary(session_id) do
    sessions = socket.assigns[:cli_sessions] || %{}
    sessions = Map.put(sessions, conversation_id, %{backend: backend, session_id: session_id})

    _ =
      Handbeam.ConversationStore.update_meta(conversation_id,
        cli_backend: backend,
        cli_session_id: session_id
      )

    assign(socket, :cli_sessions, sessions)
  end

  @doc "Drop a remembered CLI session. Used when the user switches loop owner."
  @spec forget_session(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def forget_session(socket, conversation_id) when is_binary(conversation_id) do
    sessions = socket.assigns[:cli_sessions] || %{}

    _ =
      Handbeam.ConversationStore.update_meta(conversation_id,
        cli_backend: nil,
        cli_session_id: nil
      )

    assign(socket, :cli_sessions, Map.delete(sessions, conversation_id))
  end

  defp resumed_session_id(socket, conversation_id) do
    selected = socket.assigns.selected_cli

    case socket.assigns[:cli_sessions][conversation_id] || persisted_session(conversation_id) do
      %{backend: ^selected, session_id: session_id} when is_binary(session_id) -> session_id
      _ -> nil
    end
  end

  defp persisted_session(conversation_id) do
    case Handbeam.ConversationStore.get_meta(conversation_id) do
      {:ok, %{"cli_backend" => backend, "cli_session_id" => session_id}}
      when is_binary(backend) and is_binary(session_id) ->
        %{backend: backend, session_id: session_id}

      _ ->
        nil
    end
  end

  defp load_cli_models(socket, cli) do
    case Registry.list_models(cli, cwd: workspace_cwd(socket)) do
      {:ok, []} ->
        socket
        |> assign(:available_models, [])
        |> assign(:selected_model, nil)
        |> assign(:available_reasoning_levels, [])
        |> assign(:selected_reasoning_level, nil)
        |> assign(:cli_models_error, :empty)

      {:ok, models} ->
        first = hd(models)

        socket
        |> assign(:available_models, models)
        |> assign(:selected_model, first.id)
        |> assign(:cli_models_error, nil)
        |> assign_reasoning(first)

      {:error, :models_unavailable} ->
        socket
        |> assign(:available_models, [])
        |> assign(:selected_model, nil)
        |> assign(:available_reasoning_levels, [])
        |> assign(:selected_reasoning_level, nil)
        |> assign(:cli_models_error, :models_unavailable)

      {:error, :not_available} ->
        restore_handbeam(socket)

      {:error, _reason} ->
        socket
        |> assign(:available_models, [])
        |> assign(:selected_model, nil)
        |> assign(:cli_models_error, :models_unavailable)
    end
  end

  defp assign_reasoning(socket, model) do
    levels = Map.get(model, :reasoning_levels, [])
    selected = socket.assigns[:selected_reasoning_level]

    selected = if selected in levels, do: selected, else: List.first(levels)

    socket
    |> assign(:available_reasoning_levels, levels)
    |> assign(:selected_reasoning_level, selected)
  end

  defp remember_handbeam(socket) do
    if cli_selected?(socket.assigns) do
      socket
    else
      assign(socket, %{
        handbeam_models: socket.assigns.available_models,
        handbeam_selected_model: socket.assigns.selected_model,
        handbeam_reasoning_level: socket.assigns.selected_reasoning_level,
        handbeam_reasoning_levels: socket.assigns.available_reasoning_levels
      })
    end
  end

  defp restore_handbeam(socket) do
    models = socket.assigns[:handbeam_models] || socket.assigns.available_models

    socket
    |> assign(:selected_cli, nil)
    |> assign(:cli_models_error, nil)
    |> assign(:available_models, models)
    |> assign(
      :selected_model,
      socket.assigns[:handbeam_selected_model] || socket.assigns.selected_model
    )
    |> assign(
      :available_reasoning_levels,
      socket.assigns[:handbeam_reasoning_levels] || socket.assigns.available_reasoning_levels
    )
    |> assign(
      :selected_reasoning_level,
      socket.assigns[:handbeam_reasoning_level] || socket.assigns.selected_reasoning_level
    )
  end

  defp forget_current(socket) do
    case socket.assigns[:current_conversation_id] do
      id when is_binary(id) -> forget_session(socket, id)
      _ -> socket
    end
  end

  defp workspace_cwd(socket) do
    socket.assigns[:workspace_root] || File.cwd!()
  end
end

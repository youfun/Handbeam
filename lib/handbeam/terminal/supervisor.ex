defmodule Handbeam.Terminal.Supervisor do
  @moduledoc """
  Supervisor for terminal sessions.

  Uses DynamicSupervisor — sessions are started/stopped dynamically.
  Provides workspace-scoped start/stop/list/lookup API.
  """

  use DynamicSupervisor

  alias Handbeam.Terminal.{Registry, Session}

  # ── Supervisor callbacks ──

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ── Client API ──

  @doc """
  Starts a new terminal session for a workspace.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_terminal(String.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, :already_exists | term()}
  def start_terminal(workspace_id, name, opts \\ []) when is_binary(name) do
    case Registry.lookup(workspace_id, name) do
      {:ok, _pid} ->
        {:error, :already_exists}

      {:error, :not_found} ->
        child_spec = %{
          id: {workspace_id, name},
          start: {Session, :start_link, [build_session_opts(workspace_id, name, opts)]},
          restart: :temporary
        }

        DynamicSupervisor.start_child(__MODULE__, child_spec)
    end
  end

  @doc """
  Stops a terminal session and removes it from the registry.
  """
  @spec stop_terminal(String.t(), String.t()) :: :ok | {:error, :not_found | term()}
  def stop_terminal(workspace_id, name) do
    case Registry.lookup(workspace_id, name) do
      {:ok, pid} ->
        Session.close(pid)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Stops all terminal sessions for a workspace.
  """
  @spec stop_all_for_workspace(String.t()) :: :ok
  def stop_all_for_workspace(workspace_id) do
    Registry.list(workspace_id)
    |> Enum.each(fn %{pid: pid} ->
      Session.close(pid)
    end)

    Registry.remove_workspace(workspace_id)
    :ok
  end

  @doc """
  Lists all terminal sessions for a workspace.
  """
  @spec list_terminals(String.t()) :: [
          %{
            name: String.t(),
            status: atom(),
            cmd: String.t(),
            args: [String.t()],
            cwd: String.t()
          }
        ]
  def list_terminals(workspace_id) do
    Registry.list(workspace_id)
    |> Enum.map(fn %{pid: pid} ->
      info = Session.info(pid)
      Map.take(info, [:name, :status, :cmd, :args, :cwd])
    end)
  end

  @doc """
  Looks up a terminal session PID by workspace and name.
  """
  @spec lookup(String.t(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(workspace_id, name) do
    Registry.lookup(workspace_id, name)
  end

  # ── Helpers ──

  defp build_session_opts(workspace_id, name, opts) do
    opts
    |> Keyword.put(:workspace_id, workspace_id)
    |> Keyword.put(:name, name)
  end
end

defmodule Handbeam.Terminal.Registry do
  @moduledoc """
  Per-workspace terminal session registry.

  Maps `{workspace_id, terminal_name}` → session PID.
  Two spaces can have terminals with the same name.
  """

  use GenServer

  # ── Client API ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(String.t(), String.t(), pid()) :: :ok | {:error, :already_exists}
  def register(workspace_id, name, pid)
      when is_binary(workspace_id) and is_binary(name) and is_pid(pid) do
    GenServer.call(__MODULE__, {:register, workspace_id, name, pid})
  end

  @spec unregister(String.t(), String.t()) :: :ok
  def unregister(workspace_id, name)
      when is_binary(workspace_id) and is_binary(name) do
    GenServer.call(__MODULE__, {:unregister, workspace_id, name})
  end

  @spec lookup(String.t(), String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(workspace_id, name)
      when is_binary(workspace_id) and is_binary(name) do
    GenServer.call(__MODULE__, {:lookup, workspace_id, name})
  end

  @spec list(String.t()) :: [%{name: String.t(), pid: pid()}]
  def list(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:list, workspace_id})
  end

  @spec remove_workspace(String.t()) :: :ok
  def remove_workspace(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:remove_workspace, workspace_id})
  end

  # ── Server Callbacks ──

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:register, ws_id, name, pid}, _from, state) do
    key = {ws_id, name}

    if Map.has_key?(state.sessions, key) do
      {:reply, {:error, :already_exists}, state}
    else
      Process.monitor(pid)
      {:reply, :ok, %{state | sessions: Map.put(state.sessions, key, pid)}}
    end
  end

  @impl true
  def handle_call({:unregister, ws_id, name}, _from, state) do
    key = {ws_id, name}
    {:reply, :ok, %{state | sessions: Map.delete(state.sessions, key)}}
  end

  @impl true
  def handle_call({:lookup, ws_id, name}, _from, state) do
    key = {ws_id, name}

    case Map.fetch(state.sessions, key) do
      {:ok, pid} -> {:reply, {:ok, pid}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:list, ws_id}, _from, state) do
    results =
      state.sessions
      |> Enum.filter(fn {{w, _name}, _pid} -> w == ws_id end)
      |> Enum.map(fn {{_w, name}, pid} -> %{name: name, pid: pid} end)

    {:reply, results, state}
  end

  @impl true
  def handle_call({:remove_workspace, ws_id}, _from, state) do
    sessions =
      Enum.reject(state.sessions, fn {{w, _name}, _pid} -> w == ws_id end)
      |> Map.new()

    {:reply, :ok, %{state | sessions: sessions}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    sessions =
      Enum.reject(state.sessions, fn {_key, p} -> p == pid end)
      |> Map.new()

    {:noreply, %{state | sessions: sessions}}
  end
end

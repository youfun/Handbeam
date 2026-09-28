defmodule Handbeam.Search.Watcher do
  @moduledoc """
  Maintains ExFff inventories after their initial background scan.

  Each active workspace gets a recursive `FileSystem` watcher. Events are
  debounced, then applied to the existing ETS inventory and followed by a Git
  status refresh. Tool writes can call `notify_path/2`; this follows the same
  path and also covers hosts where native file watching is unavailable.
  """

  use GenServer

  require Logger

  @debounce_ms 150

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def watch(workspace, index) when is_binary(workspace) and is_pid(index) do
    cast_if_running({:watch, Path.expand(workspace), index})
  end

  def notify_path(workspace, path) when is_binary(workspace) and is_binary(path) do
    call_if_running({:path_changed, Path.expand(workspace), Path.expand(path)})
  end

  @impl true
  def init(_opts), do: {:ok, %{workspaces: %{}, watchers: %{}, monitors: %{}}}

  @impl true
  def handle_cast({:watch, workspace, index}, state) do
    case state.workspaces do
      %{^workspace => %{index: ^index}} ->
        {:noreply, state}

      %{^workspace => entry} ->
        Process.demonitor(entry.monitor, [:flush])
        monitor = Process.monitor(index)

        state = %{
          state
          | monitors:
              state.monitors
              |> Map.delete(entry.monitor)
              |> Map.put(monitor, workspace)
        }

        updated = %{entry | index: index, monitor: monitor}
        refresh_git_async(workspace, index)
        {:noreply, put_in(state.workspaces[workspace], updated)}

      _ ->
        {watcher, state} = start_watcher(workspace, state)
        monitor = Process.monitor(index)

        entry = %{
          index: index,
          watcher: watcher,
          monitor: monitor,
          pending: MapSet.new(),
          timer: nil
        }

        state = %{state | monitors: Map.put(state.monitors, monitor, workspace)}
        refresh_git_async(workspace, index)
        {:noreply, put_in(state.workspaces[workspace], entry)}
    end
  end

  @impl true
  def handle_call({:path_changed, workspace, path}, _from, state) do
    case state.workspaces do
      %{^workspace => entry} ->
        :ok = backend().update_paths(entry.index, [path])
        refresh_git_async(workspace, entry.index)
        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:file_event, watcher, {path, _events}}, state) do
    case Map.get(state.watchers, watcher) do
      nil -> {:noreply, state}
      workspace -> {:noreply, queue_path(state, workspace, path)}
    end
  end

  def handle_info({:file_event, watcher, :stop}, state) do
    {:noreply, %{state | watchers: Map.delete(state.watchers, watcher)}}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {workspace, monitors} ->
        {entry, workspaces} = Map.pop(state.workspaces, workspace)
        if entry && is_pid(entry.watcher), do: GenServer.stop(entry.watcher)
        watchers = if entry, do: Map.delete(state.watchers, entry.watcher), else: state.watchers
        {:noreply, %{state | workspaces: workspaces, watchers: watchers, monitors: monitors}}
    end
  end

  def handle_info({:flush, workspace}, state) do
    case state.workspaces do
      %{^workspace => entry} ->
        paths = MapSet.to_list(entry.pending)
        backend().update_paths(entry.index, paths)
        refresh_git_async(workspace, entry.index)
        updated = %{entry | pending: MapSet.new(), timer: nil}
        {:noreply, put_in(state.workspaces[workspace], updated)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp cast_if_running(message) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, message)
    end
  end

  defp call_if_running(message) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, message)
    end
  end

  defp start_watcher(workspace, state) do
    case FileSystem.start_link(dirs: [workspace]) do
      {:ok, pid} ->
        :ok = FileSystem.subscribe(pid)
        {pid, %{state | watchers: Map.put(state.watchers, pid, workspace)}}

      {:error, reason} ->
        Logger.warning(
          "[Search.Watcher] file watcher unavailable workspace=#{workspace} reason=#{inspect(reason)}"
        )

        {nil, state}
    end
  end

  defp queue_path(state, workspace, path) do
    case state.workspaces do
      %{^workspace => entry} ->
        if is_reference(entry.timer), do: Process.cancel_timer(entry.timer)
        timer = Process.send_after(self(), {:flush, workspace}, @debounce_ms)
        updated = %{entry | pending: MapSet.put(entry.pending, path), timer: timer}
        put_in(state.workspaces[workspace], updated)

      _ ->
        state
    end
  end

  defp refresh_git_async(workspace, index) do
    if File.dir?(workspace) do
      Task.start(fn ->
        if File.dir?(workspace) and Process.alive?(index) do
          backend().set_git_status(index, git_status(workspace))
        end
      end)
    end
  end

  defp git_status(workspace) do
    backend = Handbeam.Git.backend()

    with :ok <- backend.available(),
         {:ok, repo} <- backend.open(workspace, ceiling: Path.dirname(workspace)),
         {:ok, root} <- backend.workdir(repo),
         {:ok, %{entries: entries}} <- backend.status(repo) do
      entries
      |> Enum.flat_map(fn entry ->
        status =
          if entry.staged == nil and entry.unstaged == :new,
            do: :untracked,
            else: :modified

        [
          {Path.join(root, entry.path), status}
          | if(entry[:old_path], do: [{Path.join(root, entry.old_path), :modified}], else: [])
        ]
      end)
    else
      _ -> []
    end
  end

  defp backend do
    Application.get_env(:handbeam, :search_backend, Handbeam.Search.ExFffBackend)
  end
end

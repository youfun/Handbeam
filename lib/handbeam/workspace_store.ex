defmodule Handbeam.WorkspaceStore do
  @moduledoc """
  JSON-based workspace storage.

  Manages workspaces in `~/.handbeam/workspaces.json`.

  ## Data structure

      {
        "workspaces": [
          {
            "id": "default",
            "name": "My Workspace",
            "path": "/Users/.../.handbeam/workspace",
            "default": true,
            "added_at": "2026-05-14T...",
            "last_opened_at": "2026-05-14T..."
          }
        ]
      }

  ## API

    - `ensure_default!/0` — ensure default workspace exists
    - `list/0` — list all workspaces
    - `add/2` — add a new workspace (with validation)
    - `get/1` — get workspace by id
    - `get_by_path/1` — get workspace by path
    - `touch/1` — update last_opened_at
    - `remove/1` — remove a non-default workspace from the list
    - `storage_path/0` — path to workspaces.json
  """

  require Logger

  @default_storage "~/.handbeam/workspaces.json"

  @doc """
  Return the path to the workspaces JSON storage file.

  Resolution order:
    1. `HANDBEAM_WORKSPACES_FILE` env var
    2. `~/.handbeam/workspaces.json`
  """
  @spec storage_path() :: String.t()
  def storage_path do
    env = System.get_env("HANDBEAM_WORKSPACES_FILE")

    if is_binary(env) and env != "",
      do: Handbeam.Home.expand(env),
      else: Handbeam.Home.expand(@default_storage)
  end

  @doc """
  Ensure the default workspace exists.
  Creates the storage file and default workspace entry if necessary.

  Returns `{:ok, workspace_map}`.
  """
  @spec ensure_default!() :: {:ok, map()} | {:error, String.t()}
  def ensure_default! do
    path = storage_path()

    # Ensure parent directory exists
    parent = Path.dirname(path)
    File.mkdir_p!(parent)

    case read_storage(path) do
      {:ok, data} ->
        workspaces = Map.get(data, "workspaces", [])
        default = Enum.find(workspaces, & &1["default"])

        if default do
          Handbeam.WorkspaceSettings.ensure_file(default["path"])
          {:ok, default}
        else
          new_default = build_default_workspace()
          Handbeam.WorkspaceSettings.ensure_file(new_default["path"])

          updated =
            Map.put(data, "workspaces", [Map.delete(new_default, :__struct__) | workspaces])

          write_storage(path, updated)
          {:ok, new_default}
        end

      {:error, :not_found} ->
        new_default = build_default_workspace()
        Handbeam.WorkspaceSettings.ensure_file(new_default["path"])
        data = %{"workspaces" => [Map.delete(new_default, :__struct__)]}
        write_storage(path, data)
        {:ok, new_default}

      {:error, reason} ->
        {:error, "Failed to read workspace storage: #{inspect(reason)}"}
    end
  end

  @doc """
  List all workspaces.
  Returns empty list if the storage file doesn't exist.
  """
  @spec list() :: [map()]
  def list do
    path = storage_path()

    case read_storage(path) do
      {:ok, data} ->
        workspaces = Map.get(data, "workspaces", [])

        dev_log(
          "[WorkspaceStore] list path=#{path} count=#{length(workspaces)} " <>
            "ids=#{inspect(Enum.map(workspaces, & &1["id"]))}"
        )

        workspaces

      {:error, :not_found} ->
        []

      {:error, :corrupted} ->
        Logger.warning("[WorkspaceStore] workspaces.json is corrupted, returning empty list")
        []
    end
  end

  @doc """
  Add a new workspace by path.

  Validates:
    - path must exist
    - path must be a directory
    - path must be readable
    - path must not be a dangerous root directory

  If a workspace with the same expanded path already exists,
  returns the existing one and updates `last_opened_at`.

  Returns `{:ok, workspace_map}` or `{:error, reason}`.
  """
  @spec add(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def add(raw_path, opts \\ []) do
    expanded = Path.expand(raw_path)

    with :ok <- validate_path(expanded),
         :ok <- validate_not_dangerous(expanded),
         :ok <- validate_directory(expanded),
         :ok <- Handbeam.WorkspaceSettings.ensure_file(expanded) do
      name = Keyword.get(opts, :name, Path.basename(expanded))
      now = now_iso8601()

      data = load_storage!()
      workspaces = Map.get(data, "workspaces", [])

      # Check for duplicate by path — single reduce pass combines find + update
      {found_ws, updated_workspaces} =
        Enum.reduce(workspaces, {nil, []}, fn w, {found, acc} ->
          if w["path"] == expanded do
            updated = Map.put(w, "last_opened_at", now)
            {updated, [updated | acc]}
          else
            {found, [w | acc]}
          end
        end)

      if found_ws do
        updated_data =
          data |> Map.put("workspaces", Enum.reverse(updated_workspaces))

        write_storage(storage_path(), updated_data)
        {:ok, found_ws}
      else
        new_ws = %{
          "id" => generate_id(),
          "name" => name,
          "path" => expanded,
          "default" => false,
          "added_at" => now,
          "last_opened_at" => now
        }

        updated_data = Map.put(data, "workspaces", workspaces ++ [new_ws])
        write_storage(storage_path(), updated_data)
        {:ok, new_ws}
      end
    end
  end

  @doc """
  Get a workspace by id.
  Returns `{:ok, workspace_map}` or `{:error, :not_found}`.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(id) do
    workspaces = list()

    case Enum.find(workspaces, fn w -> w["id"] == id end) do
      nil -> {:error, :not_found}
      ws -> {:ok, ws}
    end
  end

  @doc """
  Get a workspace by expanded path.
  Returns `{:ok, workspace_map}` or `{:error, :not_found}`.
  """
  @spec get_by_path(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_by_path(path) do
    expanded = Path.expand(path)
    workspaces = list()

    case Enum.find(workspaces, fn w -> w["path"] == expanded end) do
      nil -> {:error, :not_found}
      ws -> {:ok, ws}
    end
  end

  @doc """
  Update `last_opened_at` for a workspace.
  Returns `{:ok, workspace_map}` or `{:error, :not_found}`.
  """
  @spec touch(String.t()) :: {:ok, map()} | {:error, :not_found}
  def touch(id) do
    data = load_storage!()
    workspaces = Map.get(data, "workspaces", [])

    case Enum.find_index(workspaces, fn w -> w["id"] == id end) do
      nil ->
        {:error, :not_found}

      idx ->
        now = now_iso8601()
        updated_ws = Enum.at(workspaces, idx) |> Map.put("last_opened_at", now)
        updated_workspaces = List.replace_at(workspaces, idx, updated_ws)
        updated_data = Map.put(data, "workspaces", updated_workspaces)
        write_storage(storage_path(), updated_data)
        {:ok, updated_ws}
    end
  end

  @doc """
  Remove a workspace from the list.

  Does not delete the directory on disk. The default workspace cannot be
  removed. Conversations that belonged to the workspace are left in place
  for the caller to archive.
  """
  @spec remove(String.t()) :: {:ok, map()} | {:error, :not_found | :default_workspace}
  def remove(id) when is_binary(id) do
    data = load_storage!()
    workspaces = Map.get(data, "workspaces", [])

    case Enum.find(workspaces, &(&1["id"] == id)) do
      nil ->
        {:error, :not_found}

      %{"default" => true} ->
        {:error, :default_workspace}

      workspace ->
        updated_data =
          Map.put(data, "workspaces", Enum.reject(workspaces, &(&1["id"] == id)))

        write_storage(storage_path(), updated_data)
        {:ok, workspace}
    end
  end

  # ── Private ──

  @dangerous_roots ["/", "/etc", "/System", "/bin", "/sbin", "/usr", "/var"]

  defp build_default_workspace do
    root = Handbeam.Workspace.ensure_root!()
    now = now_iso8601()

    %{
      "id" => "default",
      "name" => "My Workspace",
      "path" => root,
      "default" => true,
      "added_at" => now,
      "last_opened_at" => now
    }
  end

  defp dev_log(message) do
    if dev_env?(), do: Logger.debug(message)
  end

  defp dev_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :dev
  end

  defp validate_path(path) do
    with :ok <- validate_not_dangerous(path) do
      if File.exists?(path) do
        :ok
      else
        {:error, "Path does not exist: #{path}"}
      end
    end
  end

  defp validate_directory(path) do
    if File.dir?(path) do
      # Check readability
      case File.ls(path) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, "Cannot read directory: #{inspect(reason)}"}
      end
    else
      {:error, "Path must be a directory"}
    end
  end

  defp validate_not_dangerous(path) do
    expanded = Path.expand(path)

    is_dangerous? =
      Enum.any?(@dangerous_roots, fn root ->
        expanded == Path.expand(root)
      end)

    if is_dangerous? do
      {:error, "Path #{path} cannot be added as a workspace"}
    else
      :ok
    end
  end

  defp generate_id do
    # Simple unique id — timestamp + random
    ts = System.os_time(:millisecond)
    rand = System.unique_integer([:positive]) |> rem(100_000)
    "ws_#{ts}_#{rand}"
  end

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  # Read storage file — returns {:ok, data} or {:error, reason}
  defp read_storage(path) do
    case File.read(path) do
      {:ok, content} when content == "" ->
        {:ok, %{"workspaces" => []}}

      {:ok, content} ->
        case Handbeam.JSON.decode(content) do
          {:ok, data} when is_map(data) -> {:ok, data}
          {:ok, _} -> {:error, :corrupted}
          {:error, _} -> {:error, :corrupted}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("[WorkspaceStore] Error reading #{path}: #{inspect(reason)}")
        {:error, :corrupted}
    end
  end

  # Load storage or return empty data
  defp load_storage! do
    path = storage_path()

    case read_storage(path) do
      {:ok, data} -> data
      {:error, _} -> %{"workspaces" => []}
    end
  end

  # Atomic write: write to temp file, then rename
  defp write_storage(path, data) do
    tmp_path = path <> ".tmp.#{System.unique_integer([:positive])}"

    case Handbeam.JSON.encode(data, pretty: true) do
      {:ok, json} ->
        case File.write(tmp_path, json) do
          :ok ->
            File.rename!(tmp_path, path)
            :ok

          {:error, reason} ->
            File.rm(tmp_path)
            Logger.error("[WorkspaceStore] Error writing temp file: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("[WorkspaceStore] Error encoding JSON: #{inspect(reason)}")
        {:error, reason}
    end
  end
end

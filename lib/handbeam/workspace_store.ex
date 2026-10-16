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
    2. `:handbeam, :workspaces_file` application config
    3. `~/.handbeam/workspaces.json` under the host data directory
  """
  @spec storage_path() :: String.t()
  def storage_path do
    env = System.get_env("HANDBEAM_WORKSPACES_FILE")

    path =
      if is_binary(env) and env != "",
        do: env,
        else: Application.get_env(:handbeam, :workspaces_file) || @default_storage

    Handbeam.Home.expand(path)
  end

  @doc """
  Ensure the default workspace exists.
  Creates the storage file and default workspace entry if necessary.

  Returns `{:ok, workspace_map}`.
  """
  @spec ensure_default!() :: {:ok, map()} | {:error, term()}
  def ensure_default! do
    path = storage_path()
    with_storage_lock(path, fn -> ensure_default(path) end)
  end

  defp ensure_default(path) do
    case read_storage(path) do
      {:ok, data} ->
        ensure_default_in_storage(path, data)

      {:error, :not_found} ->
        new_default = build_default_workspace()
        data = %{"workspaces" => [new_default]}

        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- write_storage(path, data),
             :ok <- prepare_default_workspace(new_default["path"]) do
          {:ok, new_default}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_default_in_storage(path, data) do
    workspaces = Map.get(data, "workspaces", [])

    case Enum.find(workspaces, & &1["default"]) do
      nil ->
        new_default = build_default_workspace()
        updated = Map.put(data, "workspaces", [new_default | workspaces])

        with :ok <- write_storage(path, updated),
             :ok <- prepare_default_workspace(new_default["path"]) do
          {:ok, new_default}
        end

      default ->
        root = Handbeam.Workspace.default_root()
        corrected = Map.put(default, "path", root)

        write_result =
          if corrected == default do
            :ok
          else
            updated = Enum.map(workspaces, &if(&1 == default, do: corrected, else: &1))
            write_storage(path, Map.put(data, "workspaces", updated))
          end

        with :ok <- write_result,
             :ok <- prepare_default_workspace(root) do
          {:ok, corrected}
        end
    end
  end

  defp prepare_default_workspace(root) do
    with :ok <- File.mkdir_p(root),
         :ok <- Handbeam.WorkspaceSettings.ensure_file(root) do
      :ok
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
  @spec add(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def add(raw_path, opts \\ []) do
    expanded = Path.expand(raw_path)

    with :ok <- validate_path(expanded),
         :ok <- validate_not_dangerous(expanded),
         :ok <- validate_directory(expanded) do
      path = storage_path()
      with_storage_lock(path, fn -> add_workspace(path, expanded, opts) end)
    end
  end

  defp add_workspace(path, expanded, opts) do
    with {:ok, data} <- load_storage(path) do
      name = Keyword.get(opts, :name, Path.basename(expanded))
      now = now_iso8601()
      workspaces = Map.get(data, "workspaces", [])

      {found_ws, updated_workspaces} =
        Enum.reduce(workspaces, {nil, []}, fn workspace, {found, acc} ->
          if workspace["path"] == expanded do
            updated = Map.put(workspace, "last_opened_at", now)
            {updated, [updated | acc]}
          else
            {found, [workspace | acc]}
          end
        end)

      {workspace, updated_data} =
        if found_ws do
          {found_ws, Map.put(data, "workspaces", Enum.reverse(updated_workspaces))}
        else
          new_workspace = %{
            "id" => generate_id(),
            "name" => name,
            "path" => expanded,
            "default" => false,
            "added_at" => now,
            "last_opened_at" => now
          }

          {new_workspace, Map.put(data, "workspaces", workspaces ++ [new_workspace])}
        end

      with :ok <- write_storage(path, updated_data),
           :ok <- Handbeam.WorkspaceSettings.ensure_file(expanded),
           :ok <- maybe_configure_builtin_memory(expanded, opts) do
        {:ok, workspace}
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
  @spec touch(String.t()) :: {:ok, map()} | {:error, :not_found | :corrupted | :lock_aborted}
  def touch(id) do
    path = storage_path()
    with_storage_lock(path, fn -> touch_workspace(path, id) end)
  end

  defp touch_workspace(path, id) do
    with {:ok, data} <- load_storage(path) do
      workspaces = Map.get(data, "workspaces", [])

      case Enum.find_index(workspaces, fn workspace -> workspace["id"] == id end) do
        nil ->
          {:error, :not_found}

        index ->
          updated_workspace =
            workspaces
            |> Enum.at(index)
            |> Map.put("last_opened_at", now_iso8601())

          updated_data =
            Map.put(data, "workspaces", List.replace_at(workspaces, index, updated_workspace))

          with :ok <- write_storage(path, updated_data) do
            {:ok, updated_workspace}
          end
      end
    end
  end

  @doc """
  Rename a workspace. The directory on disk is not changed.
  """
  @spec rename(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :empty | :too_long | :corrupted | :lock_aborted}
  def rename(id, name) when is_binary(id) and is_binary(name) do
    with {:ok, normalized} <- normalize_name(name) do
      path = storage_path()
      with_storage_lock(path, fn -> rename_workspace(path, id, normalized) end)
    end
  end

  defp rename_workspace(path, id, normalized) do
    with {:ok, data} <- load_storage(path) do
      workspaces = Map.get(data, "workspaces", [])

      case Enum.find_index(workspaces, &(&1["id"] == id)) do
        nil ->
          {:error, :not_found}

        index ->
          updated_workspace = Enum.at(workspaces, index) |> Map.put("name", normalized)

          updated_data =
            Map.put(data, "workspaces", List.replace_at(workspaces, index, updated_workspace))

          with :ok <- write_storage(path, updated_data) do
            {:ok, updated_workspace}
          end
      end
    end
  end

  @doc false
  def normalize_name(name) when is_binary(name) do
    normalized =
      name
      |> String.replace(~r/[\r\n\t]+/u, " ")
      |> String.replace(~r/[[:cntrl:]]/u, "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    cond do
      normalized == "" -> {:error, :empty}
      String.length(normalized) > 80 -> {:error, :too_long}
      true -> {:ok, normalized}
    end
  end

  @doc """
  Remove a workspace from the list.

  Does not delete the directory on disk. The default workspace cannot be
  removed. Conversations that belonged to the workspace are left in place
  for the caller to archive.
  """
  @spec remove(String.t()) ::
          {:ok, map()} | {:error, :not_found | :default_workspace | :corrupted | :lock_aborted}
  def remove(id) when is_binary(id) do
    path = storage_path()

    case with_storage_lock(path, fn -> remove_workspace(path, id) end) do
      {:ok, workspace} = result ->
        _ = Handbeam.CodeIndex.delete_local(workspace["path"])
        result

      error ->
        error
    end
  end

  defp remove_workspace(path, id) do
    with {:ok, data} <- load_storage(path) do
      workspaces = Map.get(data, "workspaces", [])

      case Enum.find(workspaces, &(&1["id"] == id)) do
        nil ->
          {:error, :not_found}

        %{"default" => true} ->
          {:error, :default_workspace}

        workspace ->
          updated_data =
            Map.put(data, "workspaces", Enum.reject(workspaces, &(&1["id"] == id)))

          with :ok <- write_storage(path, updated_data) do
            {:ok, workspace}
          end
      end
    end
  end

  # ── Private ──

  @dangerous_roots ["/", "/etc", "/System", "/bin", "/sbin", "/usr", "/var"]

  defp build_default_workspace do
    root = Handbeam.Workspace.default_root()
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

  defp maybe_configure_builtin_memory(path, opts) do
    if Keyword.get(opts, :builtin_memory_enabled, true) == false,
      do: Handbeam.WorkspaceSettings.update_builtin_memory_enabled(path, false),
      else: :ok
  end

  defp generate_id do
    # Simple unique id — timestamp + random
    ts = System.os_time(:millisecond)
    rand = rem(System.unique_integer([:positive]), 100_000)
    "ws_#{ts}_#{rand}"
  end

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  # Read storage file — returns {:ok, data} or {:error, reason}
  defp read_storage(path) do
    case File.read(path) do
      {:ok, content} ->
        case Handbeam.JSON.decode(content) do
          {:ok, %{"workspaces" => workspaces} = data}
          when is_list(workspaces) and is_map(data) ->
            if Enum.all?(workspaces, &is_map/1), do: {:ok, data}, else: {:error, :corrupted}

          {:ok, _data} ->
            {:error, :corrupted}

          {:error, _reason} ->
            {:error, :corrupted}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("[WorkspaceStore] Error reading #{path}: #{inspect(reason)}")
        {:error, :corrupted}
    end
  end

  defp load_storage(path) do
    case read_storage(path) do
      {:ok, data} -> {:ok, data}
      {:error, :not_found} -> {:ok, %{"workspaces" => []}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def normalize_transaction_result(:aborted), do: {:error, :lock_aborted}
  def normalize_transaction_result(result), do: result

  defp with_storage_lock(path, fun) when is_function(fun, 0) do
    resource = {:handbeam_workspace_store, Handbeam.StorageLock.canonical_path(path)}

    {resource, self()}
    |> :global.trans(fun, [node()])
    |> normalize_transaction_result()
  end

  # Atomic write: write to temp file, then rename
  defp write_storage(path, data) do
    tmp_path = path <> ".tmp.#{System.unique_integer([:positive])}"

    with {:ok, json} <- Handbeam.JSON.encode(data, pretty: true),
         :ok <- File.write(tmp_path, json),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} = error ->
        File.rm(tmp_path)
        Logger.error("[WorkspaceStore] Error writing storage: #{inspect(reason)}")
        error
    end
  end
end

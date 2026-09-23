defmodule Handbeam.SessionStore.File do
  @moduledoc """
  File-backed `Handbeam.SessionStore` implementation.

  Security:
    - `session_store_dir` is validated against `~/.handbeam/sessions` via
      `Handbeam.Security.PathValidator.validate_under_root/2` to prevent path
      traversal.
    - Directories are created with mode `0700`; snapshot files are written
      with mode `0600`.
    - Snapshot content is passed through `Handbeam.Log.Redactor.redact/1` before
      being written to disk.
  """

  @behaviour Handbeam.SessionStore

  @write_mode [:write, 0600]
  @dir_mode 0o700

  alias Handbeam.Log.Redactor
  alias Handbeam.Security.PathValidator

  @impl true
  def save(session_id, snapshot, opts \\ []) do
    path = session_path(session_id, opts)
    dir = Path.dirname(path)
    :ok = PathValidator.validate_under_root(dir, store_dir(opts))
    :ok = File.mkdir_p!(dir)
    :ok = File.chmod!(dir, @dir_mode)
    snapshot = prepare_snapshot(snapshot)
    :ok = File.write!(path, Handbeam.JSON.encode!(snapshot), @write_mode)
    :ok
  end

  @impl true
  def load(session_id, opts \\ []) do
    path = session_path(session_id, opts)
    dir = Path.dirname(path)
    :ok = PathValidator.validate_under_root(dir, store_dir(opts))

    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, snapshot} <- Handbeam.JSON.decode(body) do
      {:ok, snapshot}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(session_id, opts \\ []) do
    case File.rm(session_path(session_id, opts)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_active(opts \\ []) do
    dir = store_dir(opts)
    :ok = PathValidator.validate_under_root(dir, store_dir(opts))

    case File.ls(dir) do
      {:ok, files} ->
        ids =
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(&Path.rootname/1)

        {:ok, ids}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def update(session_id, updates, opts \\ []) do
    snapshot =
      case load(session_id, opts) do
        {:ok, existing} -> Map.merge(existing, updates)
        {:error, :not_found} -> updates
        {:error, reason} -> throw({:load_failed, reason})
      end

    save(session_id, snapshot, opts)
  catch
    {:load_failed, reason} -> {:error, reason}
  end

  def session_path(session_id, opts \\ []) do
    store_dir(opts)
    |> Path.join("#{safe_session_id(session_id)}.json")
  end

  defp store_dir(opts) do
    if dir = Keyword.get(opts, :session_store_dir) do
      dir
    else
      default_store_dir()
    end
  end

  defp default_store_dir, do: Handbeam.Home.expand("~/.handbeam/sessions")

  # Recursively strip runtime handles (pids, refs, funs) and then pass the
  # entire result through Handbeam.Log.Redactor to mask sensitive keys/values
  # (api_key, token, bearer strings, etc.) before writing to disk.
  defp prepare_snapshot(snapshot) when is_map(snapshot) do
    snapshot
    |> drop_runtime_keys()
    |> Map.new(fn {key, value} -> {key, prepare_snapshot(value)} end)
    |> Redactor.redact()
  end

  defp prepare_snapshot(snapshot) when is_list(snapshot),
    do: Enum.map(snapshot, &prepare_snapshot/1)

  defp prepare_snapshot(snapshot) when is_pid(snapshot), do: nil
  defp prepare_snapshot(snapshot) when is_reference(snapshot), do: nil
  defp prepare_snapshot(snapshot) when is_function(snapshot), do: nil
  defp prepare_snapshot(snapshot), do: snapshot

  defp drop_runtime_keys(map) do
    Map.drop(map, [
      :pid,
      :agent_pid,
      :queue_pid,
      :task,
      :task_ref,
      :port,
      "pid",
      "agent_pid",
      "queue_pid",
      "task",
      "task_ref",
      "port"
    ])
  end

  defp safe_session_id(session_id) do
    session_id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
  end
end

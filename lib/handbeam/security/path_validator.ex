defmodule Handbeam.Security.PathValidator do
  @moduledoc """
  Path security validation — prevent path traversal and ensure safe file access.

  Validates that resolved paths stay within the workspace and checks file
  accessibility.
  """

  @doc """
  Validate that a path exists and is readable.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_readable(String.t()) :: :ok | {:error, String.t()}
  def validate_readable(path) do
    with :ok <- check_exists(path),
         :ok <- check_not_directory(path) do
      case File.stat(path) do
        {:ok, %{access: access}} when access in [:read, :read_write] -> :ok
        {:ok, _} -> {:error, "#{path}: Permission denied (EACCES)"}
        {:error, reason} -> {:error, "#{path}: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Validate that a path (or its parent directory) is writeable.
  """
  @spec validate_writeable(String.t()) :: :ok | {:error, String.t()}
  def validate_writeable(path) do
    if File.exists?(path) do
      if is_writeable?(path) do
        :ok
      else
        {:error, "#{path}: Read-only file (EACCES)"}
      end
    else
      target = Path.dirname(path)

      if is_writeable?(target) do
        :ok
      else
        {:error, "#{path}: Parent directory not writeable (EACCES)"}
      end
    end
  end

  @doc """
  Validate that a resolved path is within the allowed workspace.

  Each path component is canonicalized, including intermediate symlinks.
  A workspace-relative name such as `escape/repo` whose `escape` component
  points outside the workspace is rejected.
  """
  @spec validate_within_workspace(String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_within_workspace(path, workspace) when is_binary(workspace) do
    with {:ok, resolved} <- canonicalize(path),
         {:ok, ws} <- canonicalize(workspace) do
      if contained?(resolved, ws) do
        :ok
      else
        {:error, "Path traversal blocked: #{path} is outside workspace"}
      end
    else
      {:error, _} ->
        {:error, "Path traversal blocked: #{path} is outside workspace"}
    end
  end

  @doc """
  Validate that a directory path is under the allowed root directory.

  Canonicalizes both paths, resolving every existing symlink ancestor while
  retaining nonexistent tails. Like other path-based checks, this is not an
  atomic filesystem operation and cannot prevent a concurrent symlink swap.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_under_root(String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_under_root(path, root) do
    with {:ok, resolved_path} <- canonicalize(path),
         {:ok, resolved_root} <- canonicalize(root),
         true <- contained?(resolved_path, resolved_root) do
      :ok
    else
      _ -> {:error, "Path traversal blocked: #{path} is outside #{root}"}
    end
  end

  @doc """
  Canonicalize `path` by expanding `.`/`..` and resolving every existing
  symlink component. Missing tail components are appended lexically so
  `init` of a new directory still has a containment check.
  """
  @spec canonicalize(String.t()) :: {:ok, String.t()} | {:error, :symlink_loop}
  def canonicalize(path) when is_binary(path) do
    walk_parts(Path.split(Path.expand(path)), [], MapSet.new(), %{})
  end

  @doc false
  @spec resolve_symlink(String.t()) :: String.t()
  def resolve_symlink(path) do
    case canonicalize(path) do
      {:ok, resolved} -> resolved
      {:error, _} -> Path.expand(path)
    end
  end

  defp walk_parts([], acc, _stack, _cache) do
    {:ok, join_parts(acc)}
  end

  defp walk_parts([part | rest], acc, stack, cache) do
    current = join_parts(acc ++ [part])

    cond do
      MapSet.member?(stack, current) ->
        {:error, :symlink_loop}

      is_map_key(cache, current) ->
        walk_parts(rest, Path.split(cache[current]), stack, cache)

      true ->
        case File.lstat(current) do
          {:ok, %File.Stat{type: :symlink}} ->
            follow_symlink(current, rest, stack, cache)

          {:ok, _} ->
            walk_parts(rest, acc ++ [part], stack, cache)

          {:error, :enoent} ->
            {:ok, join_parts(acc ++ [part | rest])}

          {:error, _} ->
            {:ok, join_parts(acc ++ [part | rest])}
        end
    end
  end

  defp follow_symlink(current, rest, stack, cache) do
    case File.read_link(current) do
      {:ok, target} ->
        resolved =
          if Path.type(target) == :absolute do
            Path.expand(target)
          else
            Path.expand(target, Path.dirname(current))
          end

        stacked = MapSet.put(stack, current)

        with {:ok, prefix} <- walk_parts(Path.split(resolved), [], stacked, cache) do
          cache = Map.put(cache, current, prefix)
          walk_parts(rest, Path.split(prefix), stack, cache)
        end

      {:error, _} ->
        {:ok, join_parts(Path.split(current) ++ rest)}
    end
  end

  defp join_parts([]), do: ""
  defp join_parts(parts), do: Path.join(parts)

  defp contained?(path, root) do
    path = String.trim_trailing(path, "/")
    root = String.trim_trailing(root, "/")
    path == root or String.starts_with?(path, root <> "/")
  end

  # ── Private helpers ──

  defp check_exists(path) do
    if File.exists?(path), do: :ok, else: {:error, "#{path}: No such file"}
  end

  defp check_not_directory(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} -> {:error, "#{path}: Is a directory"}
      _ -> :ok
    end
  end

  defp is_writeable?(path) do
    case File.stat(path) do
      {:ok, %{access: access}} when access in [:write, :read_write] -> true
      _ -> false
    end
  end
end

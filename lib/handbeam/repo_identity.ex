defmodule Handbeam.RepoIdentity do
  @moduledoc """
  Resolves a selected directory into its checkout and workspace identities.

  Git linked worktrees share a `repo_key` and canonical `workspace_path`, while
  retaining distinct `checkout_path` values. Ordinary directories use their
  canonical path for all three values.
  """

  alias Handbeam.Git.CLI.{Detect, Exec}
  alias Handbeam.Security.PathValidator

  @type identity :: %{
          required(:kind) => :git | :directory,
          required(:repo_key) => String.t(),
          required(:workspace_path) => String.t(),
          required(:checkout_path) => String.t()
        }

  @spec resolve(Path.t()) :: {:ok, identity()} | {:error, term()}
  def resolve(path) when is_binary(path) do
    expanded = Path.expand(path)

    with {:ok, selected} <- canonical_directory(expanded),
         :ok <- reject_managed_worktree(selected) do
      resolve_git(expanded, selected)
    end
  end

  def resolve(_path), do: {:error, :invalid_path}

  @doc "Canonicalize and validate an existing, readable directory."
  @spec canonical_directory(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def canonical_directory(path) when is_binary(path) do
    with {:ok, canonical} <- PathValidator.canonicalize(path),
         {:ok, stat} <- File.stat(canonical),
         :ok <- require_directory(stat),
         {:ok, _entries} <- File.ls(canonical) do
      {:ok, canonical}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, :enotdir} -> {:error, :not_directory}
      {:error, :eacces} -> {:error, :unreadable}
      {:error, :symlink_loop} -> {:error, :symlink_loop}
      {:error, reason} -> {:error, reason}
    end
  end

  def canonical_directory(_path), do: {:error, :invalid_path}

  defp require_directory(%File.Stat{type: :directory}), do: :ok
  defp require_directory(_stat), do: {:error, :not_directory}

  defp reject_managed_worktree(path) do
    path
    |> Path.split()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn pair -> pair == [".handbeam", "worktrees"] end)
    |> if(do: {:error, :managed_worktree}, else: :ok)
  end

  defp resolve_git(git_cwd, selected) do
    case Detect.resolve_executable() do
      {:ok, executable} -> resolve_with_git(executable, git_cwd, selected)
      {:error, _reason} -> directory_identity(selected)
    end
  end

  defp resolve_with_git(executable, git_cwd, selected) do
    with {:ok, true} <- inside_worktree?(executable, git_cwd),
         {:ok, checkout_path} <- git_path(executable, git_cwd, "--show-toplevel"),
         {:ok, common_dir} <- git_path(executable, git_cwd, "--git-common-dir"),
         {:ok, workspace_path} <- workspace_path(executable, git_cwd, common_dir) do
      {:ok,
       %{
         kind: :git,
         repo_key: common_dir,
         workspace_path: workspace_path,
         checkout_path: checkout_path
       }}
    else
      {:ok, false} -> directory_identity(selected)
      {:error, {:git_unavailable, _reason}} -> directory_identity(selected)
      {:error, reason} -> {:error, reason}
    end
  end

  defp inside_worktree?(executable, selected) do
    case run(executable, selected, ["rev-parse", "--is-inside-work-tree"]) do
      {:ok, output} -> {:ok, command_value(output) == "true"}
      {:error, {:git_exit, _code, _output}} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_path(executable, selected, flag) do
    with {:ok, output} <- run(executable, selected, ["rev-parse", "--path-format=absolute", flag]),
         value when value != "" <- command_value(output),
         {:ok, canonical} <- PathValidator.canonicalize(value),
         {:ok, %File.Stat{type: :directory}} <- File.stat(canonical),
         {:ok, _entries} <- File.ls(canonical) do
      {:ok, canonical}
    else
      "" -> {:error, :malformed_git_identity}
      {:ok, %File.Stat{}} -> {:error, :malformed_git_identity}
      {:error, :eacces} -> {:error, :unreadable_git_identity}
      {:error, reason} -> {:error, reason}
    end
  end

  defp workspace_path(executable, selected, common_dir) do
    if Path.basename(common_dir) == ".git" do
      root = Path.dirname(common_dir)

      if File.dir?(root), do: {:ok, root}, else: {:error, :malformed_git_identity}
    else
      with {:ok, output} <- run(executable, selected, ["worktree", "list", "--porcelain"]),
           {:ok, main_path} <- parse_main_worktree(output),
           {:ok, canonical} <- canonical_directory(main_path) do
        {:ok, canonical}
      end
    end
  end

  defp parse_main_worktree(output) do
    blocks =
      output
      |> String.trim()
      |> String.split(~r/\n\s*\n/, trim: true)

    paths =
      Enum.map(blocks, fn block ->
        block
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn
          "worktree " <> path -> String.trim(path)
          _line -> nil
        end)
      end)

    case paths do
      [main | _] when is_binary(main) and main != "" ->
        if Enum.all?(paths, &is_binary/1) and Enum.uniq(paths) == paths,
          do: {:ok, main},
          else: {:error, :malformed_worktree_list}

      _ ->
        {:error, :malformed_worktree_list}
    end
  end

  defp command_value(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> case do
      nil -> ""
      value -> String.trim(value)
    end
  end

  defp run(executable, cwd, args) do
    case Exec.run(executable, args, cwd: cwd, timeout: 10_000) do
      {:ok, _output, %{timed_out: true}} -> {:error, :git_timeout}
      {:ok, output, %{exit_code: 0}} -> {:ok, output}
      {:ok, output, %{exit_code: code}} -> {:error, {:git_exit, code, String.trim(output)}}
      {:error, reason} -> {:error, {:git_unavailable, reason}}
    end
  end

  defp directory_identity(selected) do
    {:ok,
     %{
       kind: :directory,
       repo_key: selected,
       workspace_path: selected,
       checkout_path: selected
     }}
  end
end

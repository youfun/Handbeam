defmodule Handbeam.CodeIndex.Location do
  @moduledoc """
  Chooses the SQLite directory for a workspace code index.

  Imported copies and unwritable roots never receive an index inside the
  workspace. Write failure is a fallback, not the only decision.
  """

  alias Handbeam.Host

  @imported "imported_workspaces"

  @spec resolve(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def resolve(workspace_root, workspace_id)
      when is_binary(workspace_root) and is_binary(workspace_id) do
    root = Path.expand(workspace_root)

    cond do
      workspace_id == "" ->
        {:error, :missing_workspace_id}

      imported?(root) or not writable_workspace?(root) ->
        {:ok, fallback_dir(workspace_id)}

      true ->
        prefer_workspace_dir(root, workspace_id)
    end
  end

  def resolve(_, _), do: {:error, :invalid_workspace}

  @spec fallback_dir(String.t()) :: Path.t()
  def fallback_dir(workspace_id) do
    Path.join([Host.data_dir(), ".handbeam", "code-index", workspace_id])
  end

  @spec imported?(Path.t()) :: boolean()
  def imported?(root) do
    root
    |> Path.split()
    |> Enum.any?(&(&1 == @imported))
  end

  defp prefer_workspace_dir(root, workspace_id) do
    dir = Path.join([root, ".handbeam", "code-index"])

    case ensure_writable(dir) do
      :ok -> {:ok, dir}
      {:error, _} -> {:ok, ensure_fallback!(workspace_id)}
    end
  end

  defp writable_workspace?(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory, access: access}} when access in [:read_write, :write] ->
        true

      {:ok, %File.Stat{type: :directory}} ->
        probe_write(root)

      _ ->
        false
    end
  end

  defp probe_write(root) do
    probe = Path.join(root, ".handbeam-index-write-probe")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        true

      {:error, _} ->
        false
    end
  end

  defp ensure_writable(dir) do
    with :ok <- File.mkdir_p(dir) do
      probe = Path.join(dir, ".write-probe")

      case File.write(probe, "") do
        :ok ->
          File.rm(probe)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_fallback!(workspace_id) do
    dir = fallback_dir(workspace_id)
    File.mkdir_p!(dir)
    dir
  end
end

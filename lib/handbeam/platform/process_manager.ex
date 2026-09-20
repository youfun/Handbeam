defmodule Handbeam.Platform.ProcessManager do
  @moduledoc """
  Cross-platform process tree termination.

  On Unix: uses `kill -9 -<pid>` to kill the process group.
  On Windows: uses `taskkill /F /T /PID <pid>`.
  Never crashes — logs failures and returns :ok.
  """

  require Logger

  alias Handbeam.Platform

  @doc """
  Kills a process and its entire child tree.

  Returns `:ok` in all cases. `nil` pid is a no-op.
  """
  @spec kill_process_tree(integer() | nil) :: :ok
  def kill_process_tree(nil), do: :ok

  def kill_process_tree(os_pid) when is_integer(os_pid) and os_pid > 0 do
    if Platform.windows?() do
      kill_windows(os_pid)
    else
      kill_unix(os_pid)
    end
  rescue
    e ->
      Logger.debug("[ProcessManager] kill failed pid=#{os_pid}: #{Exception.message(e)}")
      :ok
  end

  def kill_process_tree(_invalid), do: :ok

  @doc "Kills only the named process, without process-group signalling."
  @spec kill_process(integer() | nil) :: :ok
  def kill_process(nil), do: :ok

  def kill_process(os_pid) when is_integer(os_pid) and os_pid > 0 do
    if Platform.windows?() do
      _ = System.cmd("taskkill", ["/F", "/PID", "#{os_pid}"], stderr_to_stdout: true)
    else
      _ = System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  end

  def kill_process(_invalid), do: :ok

  # ── Platform-specific ──

  defp kill_unix(os_pid) do
    os_pid
    |> unix_process_tree()
    |> Enum.each(fn pid ->
      _ = System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
    end)

    :ok
  end

  # Kill an explicit descendant snapshot instead of signalling `-pid`. A Port
  # normally inherits the BEAM's process group, so a guessed group id can kill
  # the host process that owns the Port.
  defp unix_process_tree(root_pid) do
    case System.cmd("ps", ["-e", "-o", "pid=", "-o", "ppid="], stderr_to_stdout: true) do
      {output, 0} ->
        children =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, acc ->
            case line |> String.split() |> Enum.map(&Integer.parse/1) do
              [{pid, ""}, {parent, ""}] -> Map.update(acc, parent, [pid], &[pid | &1])
              _ -> acc
            end
          end)

        descendants_postorder(root_pid, children) ++ [root_pid]

      _ ->
        [root_pid]
    end
  end

  defp descendants_postorder(pid, children) do
    children
    |> Map.get(pid, [])
    |> Enum.flat_map(fn child -> descendants_postorder(child, children) ++ [child] end)
  end

  defp kill_windows(os_pid) do
    _ = System.cmd("taskkill", ["/F", "/T", "/PID", "#{os_pid}"], stderr_to_stdout: true)
    :ok
  end
end

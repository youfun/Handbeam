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

  # ── Platform-specific ──

  defp kill_unix(os_pid) do
    _ = System.cmd("kill", ["-9", "-#{os_pid}"], stderr_to_stdout: true)
    :ok
  end

  defp kill_windows(os_pid) do
    _ = System.cmd("taskkill", ["/F", "/T", "/PID", "#{os_pid}"], stderr_to_stdout: true)
    :ok
  end
end

defmodule Handbeam.Platform.ProcessManager do
  @moduledoc """
  Cross-platform process tree termination.

  On Unix: uses `kill -9 -<pid>` to kill the process group.
  On Windows: uses `taskkill /F /T /PID <pid>`.
  The legacy synchronous API logs failures and returns :ok. The job API separately
  verifies group identity and reports unconfirmed cleanup instead of claiming success.
  """

  require Logger

  alias Handbeam.Platform

  @doc "Job process-group verification is currently supported only on Linux with /proc."
  def jobs_supported?, do: :os.type() == {:unix, :linux} and File.dir?("/proc/self")

  @doc "Verifies the gated Port shell is both session and process-group leader."
  def verify_job_group(pid) when is_integer(pid) and pid > 1 do
    case proc_stat(pid) do
      {:ok, %{group: ^pid, session: ^pid, started: started}} ->
        {:ok, %{pid: pid, started: started}}

      _ ->
        {:error, "Job shell does not have a verified independent process group"}
    end
  end

  def verify_job_group(_), do: {:error, "Job shell PID unavailable"}

  @doc """
  Kills a previously verified job group, including descendants after the leader exits.
  Returns :ok only when /proc confirms no live members; zombies cannot execute.
  Escaped sessions/groups are not contained. Callers retain responsibility on uncertainty.
  """
  def cleanup_job_group(%{pid: group, started: started}) when is_integer(group) and group > 1 do
    with :ok <- same_group_generation(group, started),
         {:ok, members} <- group_members(group) do
      if members == [] do
        :ok
      else
        case System.cmd("kill", ["-KILL", "--", "-#{group}"], stderr_to_stdout: true) do
          {_, 0} ->
            confirm_group_empty(group)

          _ ->
            case confirm_group_empty(group) do
              :ok -> :ok
              _ -> {:error, "Process group kill failed; cleanup unconfirmed"}
            end
        end
      end
    end
  rescue
    _ -> {:error, "Process group cleanup unavailable"}
  end

  defp same_group_generation(group, started) do
    case proc_stat(group) do
      {:ok, %{started: ^started}} ->
        :ok

      {:error, :enoent} ->
        :ok

      _ ->
        {:error, "Process identity changed or cannot be verified; refusing to signal reused PID"}
    end
  end

  defp confirm_group_empty(group) do
    case group_members(group) do
      {:ok, []} -> :ok
      {:ok, _} -> {:error, "Process group still has live members"}
      error -> error
    end
  end

  defp group_members(group) do
    with {:ok, names} <- File.ls("/proc") do
      Enum.reduce_while(names, {:ok, []}, fn name, {:ok, members} ->
        case Integer.parse(name) do
          {pid, ""} ->
            case proc_stat(pid) do
              {:ok, %{group: ^group, state: state}} when state not in ["Z", "X"] ->
                {:cont, {:ok, [pid | members]}}

              {:ok, _} ->
                {:cont, {:ok, members}}

              {:error, :enoent} ->
                {:cont, {:ok, members}}

              _ ->
                {:halt, {:error, "Cannot verify process group membership"}}
            end

          _ ->
            {:cont, {:ok, members}}
        end
      end)
    end
  end

  defp proc_stat(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat") do
      # comm may contain spaces and closing parentheses; fields follow its final ')'.
      fields = stat |> String.split(") ") |> List.last() |> String.split()

      case fields do
        [state, _parent, group, session | _] ->
          {:ok,
           %{
             state: state,
             group: String.to_integer(group),
             session: String.to_integer(session),
             started: Enum.at(fields, 19)
           }}

        _ ->
          {:error, :invalid_stat}
      end
    end
  end

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
    _ = System.cmd("kill", ["-9", "--", "-#{os_pid}"], stderr_to_stdout: true)
    :ok
  end

  defp kill_windows(os_pid) do
    _ = System.cmd("taskkill", ["/F", "/T", "/PID", "#{os_pid}"], stderr_to_stdout: true)
    :ok
  end
end

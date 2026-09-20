defmodule Handbeam.Platform.ProcessRunner do
  @moduledoc """
  Executes bash commands via Port with timeout control and process cleanup.

  Encapsulates shell resolution, Port lifecycle, output collection,
  timeout handling, and cross-platform process tree termination.
  """

  alias Handbeam.Platform.{ProcessManager, ProcessSandbox, ShellResolver}

  @max_output_bytes 50_000
  @max_output_lines 2_000
  @buffer_limit 102_400

  @doc """
  Opens a gated shell using the same shell resolution and Port transport as synchronous Bash.
  No user command executes until the owner sends `go\\n`. EOF before that exits the shell.
  Job cleanup must be registered before releasing the gate.
  """
  def open_gated_bash(command, cwd, opts \\ []) do
    with {:ok, shell} <- ShellResolver.resolve(opts) do
      options = [:binary, :exit_status, :use_stdio, :stderr_to_stdout, :hide]
      options = if cwd, do: [{:cd, String.to_charlist(cwd)} | options], else: options

      script =
        "printf 'handbeam-ready\\n'; IFS= read -r gate && [ \"$gate\" = go ] || exit 125; eval \"$1\""

      try do
        port =
          Port.open(
            {:spawn_executable, shell.path},
            [{:args, shell.args ++ [script, "handbeam-job", command]} | options]
          )

        deadline =
          System.monotonic_time(:millisecond) + Keyword.get(opts, :startup_timeout, 1_000)

        case await_gate(port, "", deadline) do
          :ok ->
            {:ok, port, get_os_pid(port)}

          :error ->
            safe_close_port(port)
            {:error, "Job shell did not reach its startup gate"}
        end
      rescue
        _ -> {:error, "Failed to open job shell"}
      end
    end
  end

  # Port.open may return before the OS child has established its own session.
  # A shell handshake, not a sleep/retry, makes group verification deterministic.
  defp await_gate(_port, "handbeam-ready\n", _deadline), do: :ok
  defp await_gate(_port, output, _deadline) when byte_size(output) >= 15, do: :error

  defp await_gate(port, output, deadline) do
    receive do
      {^port, {:data, data}} -> await_gate(port, output <> data, deadline)
      {^port, {:exit_status, _}} -> :error
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> :error
    end
  end

  @type run_meta :: %{
          optional(:exit_code) => non_neg_integer(),
          timed_out: boolean()
        }

  @doc """
  Runs a bash command and returns output with metadata.

  ## Options
    - `:shell_path` — explicit shell binary path
    - `:workspace_path` — confines writes to this workspace using an OS sandbox
  """
  @spec run_bash(binary(), Path.t() | nil, timeout(), keyword()) ::
          {:ok, binary(), run_meta()} | {:error, String.t()}
  def run_bash(command, cwd, timeout_ms, opts \\ []) do
    with {:ok, shell} <- ShellResolver.resolve(opts),
         {:ok, invocation} <- ProcessSandbox.wrap(shell, command, cwd, opts) do
      port_opts = [:binary, :exit_status, :use_stdio, :stderr_to_stdout, :hide]

      port_opts =
        if invocation.cwd,
          do: [{:cd, String.to_charlist(invocation.cwd)} | port_opts],
          else: port_opts

      try do
        port =
          Port.open(
            {:spawn_executable, invocation.executable},
            [{:args, invocation.args} | port_opts]
          )

        os_pid = get_os_pid(port)
        collect_output(port, os_pid, timeout_ms, Keyword.has_key?(opts, :workspace_path))
      rescue
        e -> {:error, "Failed to spawn: #{Exception.message(e)}"}
      end
    end
  end

  # ── Output collection ──

  defp collect_output(port, os_pid, timeout_ms, sandboxed?) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    state = %{chunks: [], buf_bytes: 0, total_bytes: 0}
    do_collect(port, os_pid, deadline, state, timeout_ms, sandboxed?)
  end

  defp do_collect(port, os_pid, deadline, state, original_timeout, sandboxed?) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      if sandboxed?,
        do: ProcessManager.kill_process(os_pid),
        else: ProcessManager.kill_process_tree(os_pid)

      safe_close_port(port)
      output = build_output(state)

      {:ok, output <> "\n\n[Command timed out after #{div(original_timeout, 1000)}s]",
       %{timed_out: true}}
    else
      receive do
        {^port, {:data, data}} ->
          state = ingest_chunk(state, data)
          do_collect(port, os_pid, deadline, state, original_timeout, sandboxed?)

        {^port, {:exit_status, exit_code}} ->
          output = build_output(state)

          if exit_code == 0 do
            {:ok, output, %{exit_code: 0, timed_out: false}}
          else
            content = if output == "", do: "", else: output <> "\n\n"

            {:ok, "#{content}Command exited with code #{exit_code}",
             %{exit_code: exit_code, timed_out: false}}
          end
      after
        min(remaining, 200) ->
          do_collect(port, os_pid, deadline, state, original_timeout, sandboxed?)
      end
    end
  end

  # ── Buffer management ──

  defp ingest_chunk(state, data) do
    size = byte_size(data)
    new_total = state.total_bytes + size
    new_chunks = [data | state.chunks]
    new_buf = state.buf_bytes + size

    {trimmed, trimmed_bytes} =
      if new_buf > @buffer_limit do
        trim_buffer(new_chunks, new_buf)
      else
        {new_chunks, new_buf}
      end

    %{state | chunks: trimmed, buf_bytes: trimmed_bytes, total_bytes: new_total}
  end

  defp trim_buffer(chunks, buf) when buf <= @buffer_limit, do: {chunks, buf}

  defp trim_buffer(chunks, buf) do
    [oldest | rest] = Enum.reverse(chunks)
    trim_buffer(Enum.reverse(rest), buf - byte_size(oldest))
  end

  defp build_output(%{chunks: chunks, total_bytes: total}) do
    raw = chunks |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim_trailing("\n")

    output =
      if total > @max_output_bytes do
        lines = String.split(raw, "\n")
        kept = Enum.take(lines, -@max_output_lines)
        "[#{length(lines) - length(kept)} lines omitted]\n" <> Enum.join(kept, "\n")
      else
        if length(String.split(raw, "\n")) > @max_output_lines do
          lines = String.split(raw, "\n")
          kept = Enum.take(lines, -@max_output_lines)
          "[#{length(lines) - length(kept)} lines omitted]\n" <> Enum.join(kept, "\n")
        else
          raw
        end
      end

    if output == "", do: "(no output)", else: output
  end

  # ── Helpers ──

  defp get_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp safe_close_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
  rescue
    _ -> :ok
  end
end

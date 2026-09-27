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
  @release_env ~w(BINDIR EMU PROGNAME RELEASE_NAME RELEASE_ROOT RELEASE_VSN ROOTDIR)

  @doc """
  Opens a gated shell using the same shell resolution and Port transport as synchronous Bash.
  No user command executes until the owner sends `go\\n`. EOF before that exits the shell.
  Job cleanup must be registered before releasing the gate.
  """
  def open_gated_bash(command, cwd, opts \\ []) do
    script =
      "printf 'handbeam-ready\\n'; IFS= read -r gate && [ \"$gate\" = go ] || exit 125; eval \"$1\""

    with {:ok, shell} <- ShellResolver.resolve(opts),
         {:ok, invocation} <-
           ProcessSandbox.wrap(
             %{shell | args: shell.args ++ [script, "handbeam-job"]},
             command,
             cwd,
             opts
           ) do
      options = port_options(invocation)

      try do
        port =
          Port.open(
            {:spawn_executable, invocation.executable},
            [{:args, invocation.args} | options]
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
    business = Keyword.get(opts, :owner, self())

    child_opts =
      Keyword.merge(opts,
        command: command,
        cwd: cwd,
        business_owner: business,
        reply_to: self()
      )

    case Handbeam.Platform.ProcessRunner.InvocationSupervisor.start_invocation(child_opts) do
      {:ok, pid} -> collect_invocation(pid, timeout_ms)
      {:error, reason} -> {:error, "Failed to start invocation: #{inspect(reason)}"}
    end
  end

  def open_tracked(opts) do
    with {:ok, shell} <- ShellResolver.resolve(opts),
         {:ok, invocation} <- ProcessSandbox.wrap(shell, opts[:command], opts[:cwd], opts) do
      port =
        Port.open(
          {:spawn_executable, invocation.executable},
          [{:args, invocation.args} | port_options(invocation)]
        )

      {:ok, port, get_os_pid(port), invocation}
    end
  end

  # ── Output collection ──

  defp port_options(invocation) do
    options = [:binary, :exit_status, :use_stdio, :stderr_to_stdout, :hide]

    env =
      Enum.map(@release_env, &{String.to_charlist(&1), false}) ++
        Enum.map(child_env(invocation.env), fn {key, value} ->
          {String.to_charlist(key), String.to_charlist(value)}
        end)

    options = [{:env, env} | options]

    if invocation.cwd,
      do: [{:cd, String.to_charlist(invocation.cwd)} | options],
      else: options
  end

  # Desktop releases prepend `<release>/erts-*/bin` to PATH. Unsetting
  # BINDIR/ROOTDIR is not enough: bash then finds that `erl`, and `mix` demands
  # the release boot file instead of the machine's dev OTP. Drop only those
  # directories. Mobile hosts keep their packaged OTP; they do not use bash mix.
  @doc false
  def shell_prelude do
    unset = "unset " <> Enum.join(@release_env, " ")

    case sanitized_path() do
      nil -> unset
      path -> unset <> "; export PATH=" <> shell_quote(path)
    end
  end

  defp child_env(extra) do
    case sanitized_path() do
      nil -> extra
      path -> [{"PATH", path} | extra]
    end
  end

  defp sanitized_path do
    case System.get_env("PATH") do
      path when is_binary(path) and path != "" -> strip_release_erts(path)
      _ -> nil
    end
  end

  defp shell_quote(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end

  defp strip_release_erts(path) do
    path
    |> String.split(":", trim: true)
    |> Enum.reject(&release_erts_dir?/1)
    |> Enum.join(":")
  end

  defp release_erts_dir?(dir) do
    expanded = Path.expand(dir)
    # <release>/erts-<vsn>/bin — the release root is the parent of erts-*, not of bin.
    erts = Path.dirname(expanded)
    release = Path.dirname(erts)

    not Handbeam.Host.packaged_mix_toolchain?() and
      Path.basename(expanded) == "bin" and
      String.starts_with?(Path.basename(erts), "erts-") and
      File.regular?(Path.join(release, "releases/start_erl.data"))
  end

  # Linux kills the PID namespace init. macOS verifies and kills the independent
  # process group established before Seatbelt. Unconfined shells use a tree snapshot.
  defp collect_invocation(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    _ = Process.monitor(pid)
    do_collect_invocation(pid, deadline, %{chunks: [], buf_bytes: 0, total_bytes: 0}, timeout_ms)
  end

  defp do_collect_invocation(pid, deadline, state, original_timeout) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      GenServer.cast(pid, :cancel)

      {:ok,
       build_output(state) <> "\n\n[Command timed out after #{div(original_timeout, 1000)}s]",
       %{timed_out: true}}
    else
      receive do
        {:invocation_data, ^pid, data} ->
          do_collect_invocation(pid, deadline, ingest_chunk(state, data), original_timeout)

        {:invocation_result, ^pid, {:ok, output, meta}} ->
          formatted = build_output(state) |> String.trim_trailing("\n")

          formatted =
            cond do
              formatted == "(no output)" -> output
              is_integer(meta[:exit_code]) and meta[:exit_code] != 0 -> output
              true -> formatted
            end

          {:ok, formatted, meta}

        {:invocation_result, ^pid, {:error, reason}} ->
          {:error, reason}

        {:DOWN, _ref, :process, ^pid, {:open_failed, reason}} ->
          {:error, reason}

        {:invocation_opened, ^pid, _os_pid} ->
          do_collect_invocation(pid, deadline, state, original_timeout)
      after
        min(remaining, 200) ->
          do_collect_invocation(pid, deadline, state, original_timeout)
      end
    end
  end

  def track_owned(owner, os_pid, invocation) when is_pid(owner) and is_integer(os_pid) do
    ensure_tracker()
    :ets.insert(:handbeam_owned_os, {owner, os_pid, invocation})
    :ok
    send(owner, {:os_process_started, os_pid, invocation})
    :ok
  end

  def track_owned(_owner, _os_pid, _invocation), do: :ok

  def cleanup_owner(owner) when is_pid(owner) do
    ensure_tracker()

    :handbeam_owned_os
    |> :ets.lookup(owner)
    |> Enum.each(fn {_owner, os_pid, invocation} -> cleanup_owned(os_pid, invocation) end)

    :ets.delete(:handbeam_owned_os, owner)
    :ok
  end

  defp ensure_tracker do
    if :ets.whereis(:handbeam_owned_os) == :undefined do
      :ets.new(:handbeam_owned_os, [:named_table, :public, :bag])
    end

    :ok
  end

  def cleanup_owned(os_pid, invocation) when is_integer(os_pid) do
    cleanup_timeout(os_pid, invocation)
  end

  defp cleanup_timeout(os_pid, %{pid_namespace?: true}),
    do: ProcessManager.kill_process(os_pid)

  defp cleanup_timeout(os_pid, %{process_group?: true}),
    do: ProcessManager.kill_process_group(os_pid)

  defp cleanup_timeout(os_pid, _invocation),
    do: ProcessManager.kill_process_tree(os_pid)

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

  def os_pid(port), do: get_os_pid(port)

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

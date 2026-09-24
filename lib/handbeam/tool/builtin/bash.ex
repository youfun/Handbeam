defmodule Handbeam.Tool.Builtin.Bash do
  @moduledoc """
  Execute shell commands with timeout control and process tree killing.

  Uses Port-based execution with scroll buffer, output truncation (tail strategy),
  and process group killing on timeout.
  """

  @behaviour Handbeam.Agent.Tool

  @max_output_bytes 50_000

  @impl true
  def name, do: "bash"

  @impl true
  def description do
    "Execute a bash command in the current working directory. " <>
      "Returns stdout and stderr. Use Unix-style commands and forward-slash paths " <>
      "(ls, cat, grep, find, rm, ./scripts/test.sh) even on Windows — " <>
      "this tool always runs in a bash environment. " <>
      "Supports timeout control and working directory override. " <>
      "Runs inside an OS sandbox (Linux Bubblewrap, macOS Seatbelt): the host filesystem " <>
      "is readable, writes are allowed only in the workspace and $TMPDIR, network is not " <>
      "restricted. Writes elsewhere fail with 'Operation not permitted' or 'Read-only file " <>
      "system'. Only after such a sandbox denial, retry with unsandboxed=true; that always " <>
      "asks the user for approval. " <>
      "Set job=true for a run-scoped job (Linux only). Query job_status until finished before " <>
      "ending this run: run completion cancels unfinished jobs. Not a detached dev server; " <>
      "descendants that escape the process group are not contained."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        command: %{
          type: "string",
          description:
            "Bash command to execute. Use Unix-style commands with forward-slash paths " <>
              "(e.g. ls, cat, grep, find). Do not prefix with cd — this tool sets the " <>
              "working directory automatically."
        },
        timeout: %{type: "integer", description: "Timeout in seconds", default: 120},
        job: %{type: "boolean", default: false, description: "Explicit run-scoped job mode"},
        wait_ms: %{
          type: "integer",
          default: 1_000,
          description:
            "Job response wait, capped at 5000ms and half the tool timeout. Must be positive for launch."
        },
        cwd: %{
          type: "string",
          description:
            "Optional working directory override. Use only for a subdirectory inside " <>
              "the current workspace."
        },
        unsandboxed: %{
          type: "boolean",
          default: false,
          description:
            "Run outside the OS sandbox. Use only after the sandbox denied a needed write; " <>
              "always requires user approval. Not available for job=true."
        }
      },
      required: ["command"]
    }
  end

  @impl true
  def max_result_chars, do: @max_output_bytes + 5_000

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"command" => command} = input, context) do
    timeout_sec = Map.get(input, "timeout", 120)
    working_directory = context[:working_directory]

    with :ok <- validate_command(command),
         {:ok, cwd} <- resolve_cwd(Map.get(input, "cwd"), working_directory),
         :ok <- validate_command_paths(command, cwd) do
      unsandboxed? = Map.get(input, "unsandboxed") == true

      case Map.get(input, "job", false) do
        false ->
          execute_command(command, timeout_sec, cwd, working_directory, unsandboxed?)

        true when unsandboxed? ->
          {:error, "unsandboxed is not available for job=true"}

        true when is_integer(timeout_sec) and timeout_sec in 1..3_600 ->
          Handbeam.Jobs.start(
            command,
            cwd,
            timeout_sec * 1_000,
            Map.get(input, "wait_ms", 1_000),
            context
          )
          |> Handbeam.Jobs.format()

        true ->
          {:error, "Job timeout must be an integer from 1 to 3600 seconds"}

        _ ->
          {:error, "job must be a boolean"}
      end
    end
  end

  def execute(_input, _context) do
    {:error, "command is required"}
  end

  # ── Validation ──

  defp validate_command(cmd) when not is_binary(cmd) or byte_size(cmd) == 0 do
    {:error, "command must be a non-empty string"}
  end

  defp validate_command(_), do: :ok

  defp validate_command_paths(cmd, cwd) do
    paths = Handbeam.Security.ShellPathGuard.extract_paths(cmd)

    if paths == [] or is_nil(cwd) do
      :ok
    else
      violations =
        Enum.reject(paths, fn path ->
          safe_external_shell_path?(path) or workspace_path?(path, cwd)
        end)

      if violations == [] do
        :ok
      else
        {:error,
         "Path traversal blocked in command: #{Enum.map_join(violations, ", ", &inspect/1)} outside workspace"}
      end
    end
  end

  defp safe_external_shell_path?("/dev/null"), do: true
  defp safe_external_shell_path?(_path), do: false

  defp workspace_path?(path, cwd) do
    expanded =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(Path.join(cwd, path))
      end

    resolved = Handbeam.Security.PathValidator.resolve_symlink(expanded)
    resolved_cwd = Handbeam.Security.PathValidator.resolve_symlink(Path.expand(cwd))
    String.starts_with?(resolved, resolved_cwd <> "/") or resolved == resolved_cwd
  end

  defp resolve_cwd(nil, working_directory), do: {:ok, working_directory}

  defp resolve_cwd(path, working_directory) do
    cwd =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        wd = working_directory || File.cwd!()
        Path.expand(Path.join(wd, path))
      end

    # Validate cwd stays within workspace boundary (resolving symlinks)
    case working_directory do
      nil ->
        {:ok, cwd}

      wd ->
        resolved_cwd = Handbeam.Security.PathValidator.resolve_symlink(cwd)
        resolved_wd = Handbeam.Security.PathValidator.resolve_symlink(Path.expand(wd))

        if String.starts_with?(resolved_cwd, resolved_wd <> "/") or
             resolved_cwd == resolved_wd do
          if cwd == "/" or File.dir?(cwd) do
            {:ok, cwd}
          else
            {:error, "cwd #{path} is not a directory"}
          end
        else
          {:error, "Path traversal blocked: cwd #{path} is outside workspace #{wd}"}
        end
    end
  end

  # ── Execution ──

  defp execute_command(command, timeout_sec, cwd, working_directory, unsandboxed?) do
    timeout_ms = timeout_sec * 1000
    sandboxed? = working_directory != nil and not unsandboxed?
    opts = if sandboxed?, do: [workspace_path: working_directory], else: []

    case Handbeam.Platform.ProcessRunner.run_bash(command, cwd, timeout_ms, opts) do
      {:ok, output, %{exit_code: code} = meta} when sandboxed? and code != 0 ->
        {:ok, output <> sandbox_hint(output), meta}

      {:ok, output, meta} ->
        {:ok, output, meta}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sandbox_hint(output) do
    if output =~ "Operation not permitted" or output =~ "Read-only file system" do
      "\n\n[sandbox] A write outside the workspace and $TMPDIR may have been blocked. " <>
        "If that write is required, retry with unsandboxed=true (requires user approval)."
    else
      ""
    end
  end
end

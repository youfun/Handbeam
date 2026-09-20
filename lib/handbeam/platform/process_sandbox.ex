defmodule Handbeam.Platform.ProcessSandbox do
  @moduledoc """
  Builds an OS-enforced command boundary for workspace-scoped processes.

  Linux uses Bubblewrap with a read-only host filesystem. The current workspace
  is the only host path remounted read-write; temporary files use an isolated
  tmpfs and never reach the host's `/tmp` or `/var/tmp`.
  """

  alias Handbeam.Security.PathValidator

  @type command :: %{executable: Path.t(), args: [String.t()], cwd: Path.t() | nil}

  @spec wrap(map(), String.t(), Path.t() | nil, keyword()) ::
          {:ok, command()} | {:error, String.t()}
  def wrap(shell, command, cwd, opts) do
    case Keyword.get(opts, :workspace_path) do
      nil ->
        {:ok, %{executable: shell.path, args: shell.args ++ [command], cwd: cwd}}

      workspace ->
        wrap_workspace(shell, command, cwd || workspace, workspace, opts)
    end
  end

  defp wrap_workspace(shell, command, cwd, workspace, opts) do
    workspace = PathValidator.resolve_symlink(Path.expand(workspace))
    cwd = PathValidator.resolve_symlink(Path.expand(cwd))

    with :ok <- validate_directory(workspace, "workspace"),
         :ok <- validate_directory(cwd, "cwd"),
         :ok <- PathValidator.validate_within_workspace(cwd, workspace),
         {:ok, sandbox} <- resolve_linux_sandbox(opts) do
      {:ok,
       %{
         executable: sandbox,
         args: sandbox_args(shell, command, cwd, workspace),
         cwd: nil
       }}
    end
  end

  defp resolve_linux_sandbox(opts) do
    case :os.type() do
      {:unix, :linux} ->
        case Keyword.get(opts, :sandbox_path) || System.find_executable("bwrap") do
          nil ->
            {:error,
             "Workspace-confined bash requires Bubblewrap (bwrap); refusing to run without an OS sandbox"}

          path ->
            validate_executable(path)
        end

      _ ->
        {:error,
         "Workspace-confined bash is not supported on this platform; refusing to run without an OS sandbox"}
    end
  end

  defp validate_executable(path) do
    expanded = Path.expand(path)

    if File.regular?(expanded) do
      {:ok, expanded}
    else
      {:error, "Sandbox executable not found: #{path}"}
    end
  end

  defp validate_directory(path, label) do
    if File.dir?(path), do: :ok, else: {:error, "#{label} #{path} is not a directory"}
  end

  defp sandbox_args(shell, command, cwd, workspace) do
    [
      "--die-with-parent",
      "--new-session",
      "--unshare-pid",
      "--unshare-ipc",
      "--unshare-uts",
      "--ro-bind",
      "/",
      "/",
      "--dev",
      "/dev",
      "--proc",
      "/proc",
      "--tmpfs",
      "/tmp",
      "--tmpfs",
      "/var/tmp",
      "--bind",
      workspace,
      workspace,
      "--chdir",
      cwd,
      shell.path
      | shell.args ++ [command]
    ]
  end
end

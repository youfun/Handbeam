defmodule Handbeam.Platform.WorkspaceEnvironmentTest do
  use ExUnit.Case, async: false

  alias Handbeam.Browser.Cli
  alias Handbeam.Platform.{ProcessRunner, WorkspaceEnvironment}

  setup do
    old_capture = Application.get_env(:handbeam, :workspace_environment_capture)
    WorkspaceEnvironment.clear()

    on_exit(fn ->
      if old_capture,
        do: Application.put_env(:handbeam, :workspace_environment_capture, old_capture),
        else: Application.delete_env(:handbeam, :workspace_environment_capture)

      WorkspaceEnvironment.clear()
    end)

    :ok
  end

  test "caches a complete workspace environment without mutating the BEAM environment" do
    parent = self()
    original = System.get_env("HANDBEAM_PROJECT_MARKER")

    Application.put_env(:handbeam, :workspace_environment_capture, fn path ->
      send(parent, {:captured, path})

      {:ok,
       %{
         "PATH" => "/workspace/shims:/usr/bin",
         "HANDBEAM_PROJECT_MARKER" => "project",
         "ROOTDIR" => "/packaged/release"
       }}
    end)

    assert WorkspaceEnvironment.environment(File.cwd!()) == %{
             "PATH" => "/workspace/shims:/usr/bin",
             "HANDBEAM_PROJECT_MARKER" => "project"
           }

    assert WorkspaceEnvironment.environment(File.cwd!())["HANDBEAM_PROJECT_MARKER"] == "project"
    assert_received {:captured, path}
    assert path == Path.expand(File.cwd!())
    refute_received {:captured, _}
    assert System.get_env("HANDBEAM_PROJECT_MARKER") == original
  end

  test "resolves executables from the workspace PATH" do
    root =
      Path.join(System.tmp_dir!(), "handbeam-workspace-env-#{System.unique_integer([:positive])}")

    bin = Path.join(root, "bin")
    executable = Path.join(bin, "workspace-tool")
    File.mkdir_p!(bin)
    File.write!(executable, "#!/bin/sh\n")
    File.chmod!(executable, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    Application.put_env(:handbeam, :workspace_environment_capture, fn ^root ->
      {:ok, %{"PATH" => bin}}
    end)

    assert WorkspaceEnvironment.find_executable("workspace-tool", root) == executable
  end

  test "browser CLI resolves agent-browser from the workspace environment" do
    root =
      Path.join(System.tmp_dir!(), "handbeam-browser-env-#{System.unique_integer([:positive])}")

    bin = Path.join(root, "bin")
    executable = Path.join(bin, "agent-browser")
    File.mkdir_p!(bin)

    File.write!(
      executable,
      ~S|#!/bin/sh
printf '%s:%s' "$PROJECT_BROWSER" "$PWD"
|
    )

    File.chmod!(executable, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    Application.put_env(:handbeam, :workspace_environment_capture, fn ^root ->
      {:ok, %{"PATH" => bin, "PROJECT_BROWSER" => "enabled"}}
    end)

    assert {:ok, %{exit_code: 0, stdout: output}} =
             Cli.run(["--version"], workspace_path: root)

    assert output == "enabled:#{Handbeam.Security.PathValidator.resolve_symlink(root)}"
  end

  test "bash inherits the workspace environment and explicit values win" do
    root =
      Path.join(System.tmp_dir!(), "handbeam-bash-env-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    Application.put_env(:handbeam, :workspace_environment_capture, fn ^root ->
      {:ok,
       %{
         "PATH" => System.get_env("PATH"),
         "PROJECT_ONLY" => "project",
         "PRECEDENCE" => "project"
       }}
    end)

    assert {:ok, "project:explicit", %{exit_code: 0}} =
             ProcessRunner.run_bash(
               ~S|printf '%s:%s' "$PROJECT_ONLY" "$PRECEDENCE"|,
               root,
               5_000,
               workspace_path: root,
               env: [{"PRECEDENCE", "explicit"}]
             )
  end
end

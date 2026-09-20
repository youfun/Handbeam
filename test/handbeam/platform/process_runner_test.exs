defmodule Handbeam.Platform.ProcessRunnerTest do
  use ExUnit.Case, async: false

  alias Handbeam.Platform.ProcessRunner

  describe "run_bash/4" do
    test "executes simple command and returns output" do
      {:ok, output, meta} = ProcessRunner.run_bash("echo hello", nil, 5000)

      assert output =~ "hello"
      assert meta.exit_code == 0
      assert meta.timed_out == false
    end

    test "returns error for shell resolve failure" do
      assert {:error, reason} =
               ProcessRunner.run_bash("echo test", nil, 5000, shell_path: "/nonexistent/bash_xyz")

      assert reason =~ "not found" or reason =~ "does not exist"
    end

    test "captures non-zero exit code" do
      {:ok, output, meta} = ProcessRunner.run_bash("exit 42", nil, 5000)

      assert output =~ "exited with code 42"
      assert meta.exit_code == 42
    end

    test "timeout kills process", %{test: test_name} do
      # Start a long-running sleep, expect it to be killed
      {:ok, output, meta} = ProcessRunner.run_bash("sleep 30", nil, 100)

      assert meta.timed_out == true
      assert output =~ "timed out"
    end

    test "runs with cwd", %{test: test_name} do
      tmp = System.tmp_dir!()
      {:ok, output, meta} = ProcessRunner.run_bash("pwd", tmp, 5000)

      # Output should contain the tmp directory path
      assert output =~ tmp or output =~ Path.basename(tmp)
      assert meta.exit_code == 0
    end

    test "fails closed when a workspace sandbox is unavailable" do
      workspace = File.cwd!()

      assert {:error, reason} =
               ProcessRunner.run_bash("echo unsafe", workspace, 5000,
                 workspace_path: workspace,
                 sandbox_path: "/nonexistent/bwrap"
               )

      assert reason =~ "Sandbox executable not found"
    end
  end
end

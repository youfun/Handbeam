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

    test "does not leak release launcher variables into child tools" do
      old_root = System.get_env("ROOTDIR")
      System.put_env("ROOTDIR", "/incomplete/release")

      try do
        assert {:ok, "unset", %{exit_code: 0}} =
                 ProcessRunner.run_bash("printf %s \"${ROOTDIR-unset}\"", nil, 5_000)
      after
        if old_root,
          do: System.put_env("ROOTDIR", old_root),
          else: System.delete_env("ROOTDIR")
      end
    end

    test "keeps a packaged mobile OTP erl on PATH" do
      root =
        Path.join(System.tmp_dir!(), "handbeam-mobile-otp-#{System.unique_integer([:positive])}")

      erts = Path.join(root, "erts-17.0.4/bin")
      File.mkdir_p!(erts)
      File.mkdir_p!(Path.join(root, "releases"))
      File.write!(Path.join(root, "releases/start_erl.data"), "17.0.4 0.1.0\n")
      File.write!(Path.join(erts, "erl"), "#!/bin/sh\necho packaged-erl\n")
      File.chmod!(Path.join(erts, "erl"), 0o755)

      old_path = System.get_env("PATH")
      old_host = Application.get_env(:handbeam, :host)
      System.put_env("PATH", erts <> ":" <> to_string(old_path))
      Application.put_env(:handbeam, :host, %{packaged_mix_toolchain: true})

      try do
        assert {:ok, "packaged-erl", %{exit_code: 0}} =
                 ProcessRunner.run_bash("erl", nil, 5_000)
      after
        restore_env("PATH", old_path)
        restore_app_env(:host, old_host)
        File.rm_rf!(root)
      end
    end

    test "does not resolve erl from a release ERTS directory on PATH" do
      root =
        Path.join(
          System.tmp_dir!(),
          "handbeam-release-path-#{System.unique_integer([:positive])}"
        )

      erts = Path.join(root, "erts-17.0.4/bin")
      releases = Path.join(root, "releases")
      host = Path.join(root, "host-bin")

      File.mkdir_p!(erts)
      File.mkdir_p!(releases)
      File.mkdir_p!(host)
      File.write!(Path.join(releases, "start_erl.data"), "17.0.4 0.1.0\n")
      File.write!(Path.join(erts, "erl"), "#!/bin/sh\necho release-erl\n")
      File.chmod!(Path.join(erts, "erl"), 0o755)
      File.write!(Path.join(host, "erl"), "#!/bin/sh\necho host-erl\n")
      File.chmod!(Path.join(host, "erl"), 0o755)

      old_path = System.get_env("PATH")
      System.put_env("PATH", Enum.join([erts, host, old_path], ":"))

      try do
        assert {:ok, "host-erl", %{exit_code: 0}} =
                 ProcessRunner.run_bash("erl", nil, 5_000)
      after
        restore_env("PATH", old_path)
        File.rm_rf!(root)
      end
    end

    test "fails closed when a workspace sandbox is unavailable" do
      workspace = File.cwd!()

      assert {:error, reason} =
               ProcessRunner.run_bash("echo unsafe", workspace, 5000,
                 workspace_path: workspace,
                 sandbox_path: "/nonexistent/bwrap"
               )

      assert reason =~ "Sandbox executable not found" or
               reason =~ "Workspace-confined bash is not supported"
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:handbeam, key)
  defp restore_app_env(key, value), do: Application.put_env(:handbeam, key, value)
end

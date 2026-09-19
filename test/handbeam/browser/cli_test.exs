defmodule Handbeam.Browser.CliTest do
  @moduledoc """
  Tests for the agent-browser argv planner and injectable runner.

  No Chromium is launched. The default executable lookup can be stubbed.
  """

  use ExUnit.Case, async: true

  alias Handbeam.Browser.Cli

  describe "planned_argv/2" do
    test "injects --json and the managed session" do
      argv = Cli.planned_argv(["open", "https://example.com"], session_name: "handbeam-abc")

      assert argv == ["--json", "--session", "handbeam-abc", "open", "https://example.com"]
    end

    test "does not inject session or json for inspection" do
      assert Cli.planned_argv(["--help"], session_name: "handbeam-abc") == ["--help"]
      assert Cli.planned_argv(["--version"], session_name: "handbeam-abc") == ["--version"]
    end

    test "omits --session when no managed session is provided" do
      assert Cli.planned_argv(["snapshot", "-i"], []) == ["--json", "snapshot", "-i"]
    end

    test "injects screenshot dir after session" do
      argv =
        Cli.planned_argv(["screenshot"],
          session_name: "handbeam-abc",
          screenshot_dir: "/tmp/handbeam-browser"
        )

      assert argv == [
               "--json",
               "--session",
               "handbeam-abc",
               "--screenshot-dir",
               "/tmp/handbeam-browser",
               "screenshot"
             ]
    end
  end

  describe "run/2" do
    test "calls the injected runner with planned argv and timeout" do
      test_pid = self()

      runner = fn argv, opts ->
        send(test_pid, {:ran, argv, opts})
        {:ok, %{stdout: ~s({"text":"ok"}), stderr: "", exit_code: 0, timed_out: false}}
      end

      assert {:ok, raw} =
               Cli.run(["snapshot", "-i"],
                 session_name: "handbeam-1",
                 timeout_ms: 12_000,
                 runner: runner,
                 executable: "/usr/bin/agent-browser"
               )

      assert raw.exit_code == 0
      assert_received {:ran, ["--json", "--session", "handbeam-1", "snapshot", "-i"], opts}
      assert opts[:timeout_ms] == 12_000
      assert opts[:executable] == "/usr/bin/agent-browser"
    end

    test "returns missing-binary when the executable cannot be found" do
      find = fn _name -> nil end

      assert {:error, :missing_binary, "agent-browser"} =
               Cli.run(["--version"], find_executable: find)
    end

    test "uses a default timeout when none is supplied" do
      runner = fn _argv, opts ->
        send(self(), {:timeout, opts[:timeout_ms]})
        {:ok, %{stdout: "", stderr: "", exit_code: 0, timed_out: false}}
      end

      assert {:ok, _} =
               Cli.run(["--help"], runner: runner, executable: "/usr/bin/agent-browser")

      assert_received {:timeout, 35_000}
    end
  end
end

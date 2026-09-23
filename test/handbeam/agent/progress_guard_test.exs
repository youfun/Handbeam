defmodule Handbeam.Agent.ProgressGuardTest do
  use ExUnit.Case, async: true

  alias Handbeam.Agent.ProgressGuard

  # Failure list:
  # - same edit/read with a different result must not count as a repeated call
  # - A→B→A→B on one file must stall and name the path
  # - the same bash error three times must stall
  # - 48 distinct edits must not stall
  # - after a stall, the next 8 calls are a grace period

  test "a changed read result is not a repeated call" do
    progress = ProgressGuard.initial()

    {progress, nil, nil} =
      ProgressGuard.observe(progress, obs("edit", %{"file_path" => "a.ex"}, "one", "a.ex"))

    {progress, nil, nil} =
      ProgressGuard.observe(progress, obs("read", %{"file_path" => "a.ex"}, "one", "a.ex"))

    {progress, nil, nil} =
      ProgressGuard.observe(progress, obs("edit", %{"file_path" => "a.ex"}, "two", "a.ex"))

    {progress, nil, nil} =
      ProgressGuard.observe(progress, obs("read", %{"file_path" => "a.ex"}, "two", "a.ex"))

    assert progress.quiet == 0
  end

  test "editing a file back and forth stalls with the path" do
    progress =
      Enum.reduce(["A", "B", "A"], ProgressGuard.initial(), fn content, acc ->
        {progress, signal, _} =
          ProgressGuard.observe(acc, obs("edit", %{"file_path" => "a.ex"}, content, "a.ex"))

        assert signal == nil
        progress
      end)

    {progress, signal, evidence} =
      ProgressGuard.observe(progress, obs("edit", %{"file_path" => "a.ex"}, "B", "a.ex"))

    assert signal == :edit_cycle
    assert evidence =~ "a.ex"
    assert progress.digest.files["a.ex"] != nil
  end

  test "the same command error three times stalls" do
    progress =
      Enum.reduce(1..2, ProgressGuard.initial(), fn _, acc ->
        {progress, nil, nil} =
          ProgressGuard.observe(acc, %{
            tool: "bash",
            args: %{"command" => "mix test"},
            result: "error",
            error: true,
            path: nil
          })

        progress
      end)

    {_progress, signal, evidence} =
      ProgressGuard.observe(progress, %{
        tool: "bash",
        args: %{"command" => "mix test"},
        result: "error",
        error: true,
        path: nil
      })

    assert signal == :repeated_failure
    assert evidence =~ "bash"
  end

  test "many distinct edits do not stall" do
    progress =
      Enum.reduce(1..48, ProgressGuard.initial(), fn n, acc ->
        {progress, signal, _} =
          ProgressGuard.observe(
            acc,
            obs("edit", %{"file_path" => "f#{n}.ex"}, "body #{n}", "f#{n}.ex")
          )

        assert signal == nil
        progress
      end)

    assert map_size(progress.digest.files) == 48
  end

  test "grace skips the next eight calls" do
    {_progress, signal, _} =
      ProgressGuard.observe(ProgressGuard.initial(), %{
        tool: "bash",
        args: %{"command" => "false"},
        result: "no",
        error: true,
        path: nil
      })

    progress =
      ProgressGuard.initial()
      |> then(fn progress ->
        Enum.reduce(1..3, progress, fn _, acc ->
          {progress, _, _} =
            ProgressGuard.observe(acc, %{
              tool: "bash",
              args: %{"command" => "false"},
              result: "no",
              error: true,
              path: nil
            })

          progress
        end)
      end)

    assert signal == nil

    granted = ProgressGuard.grant(progress)

    granted =
      Enum.reduce(1..8, granted, fn _, acc ->
        {progress, signal, _} =
          ProgressGuard.observe(acc, %{
            tool: "bash",
            args: %{"command" => "false"},
            result: "no",
            error: true,
            path: nil
          })

        assert signal == nil
        progress
      end)

    granted =
      Enum.reduce(1..2, granted, fn _, acc ->
        {progress, signal, _} =
          ProgressGuard.observe(acc, %{
            tool: "bash",
            args: %{"command" => "false"},
            result: "no",
            error: true,
            path: nil
          })

        assert signal == nil
        progress
      end)

    {_progress, signal, _} =
      ProgressGuard.observe(granted, %{
        tool: "bash",
        args: %{"command" => "false"},
        result: "no",
        error: true,
        path: nil
      })

    assert signal == :repeated_failure
  end

  defp obs(tool, args, result, path) do
    %{tool: tool, args: args, result: result, error: false, path: path}
  end
end

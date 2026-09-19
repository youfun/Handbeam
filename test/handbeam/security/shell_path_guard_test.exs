defmodule Handbeam.Security.ShellPathGuard.Test do
  @moduledoc """
  Tests for shell command path extraction.

  Reference: `cortex/tools/shell_path_guard.ex` (Cortex ShellPathGuard)
  Test pattern: hand-written from Cortex ShellPathGuard behavior

  Known gaps (tests prefixed `ideal_`):
    - Current extract_paths/1 splits only on shell metacharacters (;&|...),
      NOT on spaces. So "ls /etc/hosts" returns ["ls /etc/hosts"], not ["/etc/hosts"].
    - Full path extraction from space-separated arguments is a documented gap.

  Covers:
    - Current behavior: shell metacharacter splitting, comment exclusion, dedup
    - Expected (ideal) behavior: space-separated path extraction, ~ expansion
  """

  use ExUnit.Case, async: true

  alias Handbeam.Security.ShellPathGuard

  # ── Current behavior (tests pass as-is) ──

  describe "extract_paths/1 — splitting behavior" do
    test "splits on pipe metacharacter and whitespace" do
      paths = ShellPathGuard.extract_paths("cat file.txt | grep pattern")
      assert length(paths) == 4
      assert "file.txt" in paths
      assert "pattern" in paths
    end

    test "splits on semicolon and whitespace" do
      paths = ShellPathGuard.extract_paths("cat a.txt; ls b.txt")
      assert length(paths) >= 4
      assert "a.txt" in paths
      assert "b.txt" in paths
    end

    test "excludes shell comments" do
      paths = ShellPathGuard.extract_paths("# this is a comment")
      assert [] == paths or Enum.all?(paths, &(not String.starts_with?(&1, "#")))
    end

    test "deduplicates repeated path segments" do
      paths = ShellPathGuard.extract_paths("ls /tmp/a; ls /tmp/a")
      count = Enum.count(paths, &(&1 == "/tmp/a"))
      assert count == 1
    end

    test "returns empty list for empty command" do
      paths = ShellPathGuard.extract_paths("")
      assert paths == []
    end

    test "detects absolute paths" do
      paths = ShellPathGuard.extract_paths("/bin/ls")
      assert "/bin/ls" in paths
    end
  end

  # ── Expected (ideal) behavior — known gaps ──

  describe "extract_paths/1 — expected behavior" do
    test "extracts absolute paths from space-separated args" do
      paths = ShellPathGuard.extract_paths("ls /etc/hosts")
      assert "/etc/hosts" in paths
    end

    test "extracts multiple paths from a command" do
      paths = ShellPathGuard.extract_paths("cp /tmp/a.txt /tmp/b.txt")
      assert "/tmp/a.txt" in paths
      assert "/tmp/b.txt" in paths
    end

    test "extracts relative paths" do
      paths = ShellPathGuard.extract_paths("cat readme.md")
      assert "readme.md" in paths
    end

    test "extracts paths with dots and hyphens" do
      paths = ShellPathGuard.extract_paths("cat my-file_v2.txt")
      assert "my-file_v2.txt" in paths
    end

    test "expands ~ to home directory" do
      paths = ShellPathGuard.extract_paths("ls ~/Documents")
      result = Enum.find(paths, &String.starts_with?(&1, "/"))
      assert result != nil
      assert String.contains?(result, "Documents")
    end

    test "extracts from find command" do
      paths = ShellPathGuard.extract_paths("find . -name '*.ex'")
      assert "." in paths
    end

    test "extracts from grep command" do
      paths = ShellPathGuard.extract_paths("grep pattern file.txt")
      assert "file.txt" in paths
    end

    test "extracts from git command" do
      paths = ShellPathGuard.extract_paths("git log -- src/file.ex")
      assert "src/file.ex" in paths
    end

    test "extracts from mkdir command" do
      paths = ShellPathGuard.extract_paths("mkdir -p /tmp/newdir")
      assert "/tmp/newdir" in paths
    end
  end
end

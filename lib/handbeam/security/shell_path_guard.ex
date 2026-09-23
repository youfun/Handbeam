defmodule Handbeam.Security.ShellPathGuard do
  @moduledoc """
  Shell command path extraction for security auditing.

  Parses shell commands to extract file paths being accessed,
  allowing the security layer to validate them against the workspace.

  Supports common commands: ls, cat, find, grep, git, etc.
  """

  @path_commands ~w(cat ls find grep rg cp mv rm mkdir rmdir touch
                    head tail less more file stat readlink realpath
                    cd pushd popd diff cmp wc sort uniq cut sed awk
                    python python3 ruby node elixir mix iex)

  @doc """
  Extract file paths from a shell command string.

  Returns a list of paths that the command references.
  """
  @spec extract_paths(String.t()) :: [String.t()]
  def extract_paths(command) when is_binary(command) do
    _ = @path_commands

    command
    |> String.split(~r/[;&|`$(){}\[\]<>#\n]/, include_captures: false)
    |> Enum.flat_map(&String.split(&1, ~r/\s+/))
    |> Enum.flat_map(&extract_from_segment/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp extract_from_segment(segment) do
    trimmed = String.trim(segment)

    cond do
      String.starts_with?(trimmed, "#") -> []
      String.starts_with?(trimmed, "~") -> [Path.expand(trimmed)]
      String.starts_with?(trimmed, "/") and looks_like_real_path?(trimmed) -> [trimmed]
      String.match?(trimmed, ~r/^[a-zA-Z0-9_\-\.\/]/) -> [trimmed]
      true -> []
    end
  end

  # Heuristic: does this look like a real filesystem path?
  # Cross-platform (macOS + Linux): uses File.exists?/1 for ambiguous cases.
  defp looks_like_real_path?("/" <> rest) do
    cond do
      # Multiple path segments: /Users/box, /usr/local/bin
      String.contains?(rest, "/") ->
        true

      # Contains a dot: /etc/hosts, /path/to/file.ex, /path/../
      String.contains?(rest, ".") ->
        true

      # Single-segment directory name that actually exists on disk.
      # Works identically on macOS and Linux; catches /usr, /tmp, /Users, etc.
      File.exists?(Path.join("/", rest)) ->
        true

      # Single segment with non-filename characters (e.g. "skill:name").
      # Real Unix directories don't contain colons, braces, etc.
      not String.match?(rest, ~r/^[a-zA-Z0-9._-]+$/) ->
        false

      true ->
        false
    end
  end

  defp blank?(s), do: is_nil(s) or String.trim(s) == ""
end

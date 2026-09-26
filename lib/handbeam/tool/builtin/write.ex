defmodule Handbeam.Tool.Builtin.Write do
  alias Handbeam.Agent.Tool.Helpers

  @moduledoc """
  Write content to a file. Creates the file and parent directories as needed.

  Overwrites existing files. Used for creating new files or completely rewriting.
  For precise edits, use the Edit tool instead.
  """

  @behaviour Handbeam.Agent.Tool

  @impl true
  def name, do: "write"

  @impl true
  def description do
    "Write content to a file, creating parent directories if needed. " <>
      "Overwrites existing files. Use write for new files, small full-file rewrites, " <>
      "or broad changes where replacing the whole file is clearer than many edits. " <>
      "Use edit for precise text replacements, including multiple replacements in one call."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        file_path: %{
          type: "string",
          description:
            "File path inside the current workspace. Prefer a relative path such as workspace-check.txt or reports/summary.md. A leading / means filesystem root, not workspace root; absolute paths must remain inside the workspace."
        },
        content: %{type: "string", description: "Content to write to the file"}
      },
      required: ["file_path", "content"]
    }
  end

  @impl true
  def max_result_chars, do: 2_000

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"file_path" => file_path, "content" => content}, context) do
    with {:ok, path} <- Handbeam.Agent.Tool.resolve_path(Helpers.expand_tilde(file_path), context),
         :ok <- validate_within_workspace(path, context),
         :ok <- reject_directory_target(path),
         :ok <- Handbeam.Security.PathValidator.validate_writeable(Path.dirname(path)),
         {:ok, before_content} <- read_before_content(path),
         :ok <- create_parent_dirs(path) do
      case File.write(path, content) do
        :ok ->
          _ = Handbeam.Extension.HotReloader.notify_path(path)
          bytes = byte_size(content)
          lines = length(String.split(content, "\n"))
          change = Handbeam.ChangeSnapshot.build_write_snapshot(path, before_content, content)

          {:ok, "Wrote #{path} (#{bytes} bytes, #{lines} lines)",
           %{
             file_path: path,
             bytes: bytes,
             lines: lines,
             diff_lines: change.diff_lines,
             change: change,
             change_id: change.change_id,
             change_type: change.change_type,
             existed_before: change.existed_before,
             before_sha256: change.before_sha256,
             after_sha256: change.after_sha256,
             before_content: change.before_content,
             after_content: change.after_content,
             reversible: change.reversible,
             revert_status: change.revert_status,
             revert_reason: change.revert_reason
           }}

        {:error, reason} ->
          {:error, "Failed to write #{path}: #{reason}"}
      end
    end
  end

  def execute(_input, _context) do
    {:error, "file_path and content are required"}
  end

  defp read_before_content(path) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, "Cannot read existing file #{path}: #{reason}"}
      end
    else
      {:ok, nil}
    end
  end

  defp create_parent_dirs(path) do
    dir = Path.dirname(path)

    if File.exists?(dir) do
      :ok
    else
      case File.mkdir_p(dir) do
        :ok -> :ok
        {:error, reason} -> {:error, "Cannot create directory #{dir}: #{reason}"}
      end
    end
  end

  # Validates the resolved path stays within workspace, including symlink resolution.
  defp validate_within_workspace(path, %{working_directory: wd}) when is_binary(wd) do
    Handbeam.Security.PathValidator.validate_within_workspace(path, wd)
  end

  defp validate_within_workspace(_path, _context), do: :ok

  # Rejects write to an existing directory target (BDD-WRITE-006).
  defp reject_directory_target(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} -> {:error, "#{path}: Is a directory"}
      _ -> :ok
    end
  end
end

defmodule Handbeam.Agent.ContextLoader do
  @moduledoc """
  Discovers, loads, truncates, and injects AGENTS.md context files
  into the agent's system prompt.

  ## Discovery

  Walks from `cwd` upward through parent directories collecting every
  `AGENTS.md` file. Paths are sorted by depth ascending — shallowest
  (lowest priority) first, deepest (highest priority) last. The walk
  continues until the filesystem root.

  ## Loading

  Each file is read and annotated with its source path. Unreadable or
  missing files are skipped with a `Logger.warning/1` — the agent
  session never fails because of a bad AGENTS.md.

  ## Truncation

  Two hard limits protect the context window:

    - **Per-file**: 2 000 characters (default)
    - **Total**: 8 000 characters (default)

  When a limit is hit a `[TRUNCATED: ...]` marker is inserted. Files
  are never summarised or rewritten — truncated content is unambiguous.

  ## Injection

  The merged context is injected as a standalone `## Project Instructions
  (AGENTS.md)` section near the top of the system prompt. When the
  context is empty or nil the prompt is returned unchanged.
  """

  require Logger

  @max_per_file 2000
  @max_total 8000

  @doc """
  Discover AGENTS.md files walking upward from `cwd`.

  The walk stops when it reaches the project root (a directory that
  contains `mix.exs`) or the filesystem root.

  Returns absolute paths sorted by directory depth (shallowest first).

  ## Examples

      iex> paths = ContextLoader.discover()
      iex> is_list(paths)
      true
  """
  @spec discover(String.t()) :: [String.t()]
  def discover(cwd \\ File.cwd!()) do
    root = find_project_root(cwd)

    cwd
    |> walk_up(root)
    |> Enum.filter(&File.exists?/1)
    |> Enum.sort_by(&depth/1, :asc)
  end

  @doc """
  Load and merge discovered AGENTS.md files.

  Each file is annotated with its source path. Files that cannot be
  read (missing, permission denied) are skipped with a warning log.

  Returns `{:ok, merged_content}`. Never returns an error tuple —
  even when every file fails the result is `{:ok, ""}`.
  """
  @spec load([String.t()]) :: {:ok, String.t()}
  def load(paths) do
    sections =
      paths
      |> Enum.map(&load_one/1)
      |> Enum.reject(&is_nil/1)

    {:ok, Enum.join(sections)}
  end

  @doc """
  Truncate merged context to per-file and total character limits.

  Returns `{truncated_content, truncated?}`.

  ## Options

    - `:max_per_file` — chars per file section (default: 2 000)
    - `:max_total` — total chars across all sections (default: 8 000)
  """
  @spec truncate(String.t(), keyword()) :: {String.t(), boolean()}
  def truncate(content, opts \\ []) do
    max_per_file = Keyword.get(opts, :max_per_file, @max_per_file)
    max_total = Keyword.get(opts, :max_total, @max_total)

    {sections, per_file_truncated?} = truncate_per_file(content, max_per_file)

    if per_file_truncated? do
      {truncate_total(sections, max_total, true), true}
    else
      {truncate_total(sections, max_total, false), false}
    end
  end

  @doc """
  Inject AGENTS.md context into a system prompt.

  When `context` is empty or nil the prompt is returned unchanged.

  ## Examples

      iex> ContextLoader.inject("Be helpful.", "# rule")
      ...> |> String.contains?("## Project Instructions (AGENTS.md)")
      true
  """
  @spec inject(String.t(), String.t() | nil) :: String.t()
  def inject(system_prompt, context) when is_binary(context) and context != "" do
    section = """

    ## Project Instructions (AGENTS.md)

    #{String.trim_trailing(context)}
    """

    system_prompt <> section
  end

  def inject(system_prompt, _context), do: system_prompt

  # ── Private: discovery ──

  defp find_project_root(cwd) do
    cwd
    |> Stream.unfold(fn
      nil -> nil
      d -> {d, parent(d)}
    end)
    |> Enum.find(fn dir ->
      File.exists?(Path.join(dir, "mix.exs"))
    end) || cwd
  end

  defp walk_up(dir, root) do
    root_depth = depth(root)

    Stream.unfold(dir, fn
      nil ->
        nil

      d ->
        if depth(d) < root_depth do
          nil
        else
          {Path.join(d, "AGENTS.md"), parent(d)}
        end
    end)
    |> Enum.to_list()
  end

  defp parent(dir) do
    parent = Path.dirname(dir)

    if parent == dir do
      nil
    else
      parent
    end
  end

  defp depth(path) do
    path
    |> Path.dirname()
    |> Path.split()
    |> length()
  end

  # ── Private: loading ──

  defp load_one(path) do
    case File.read(path) do
      {:ok, content} ->
        "\n### From: #{path}\n#{String.trim_trailing(content)}\n"

      {:error, reason} ->
        Logger.warning("[ContextLoader] Skipping #{path}: #{:file.format_error(reason)}")

        nil
    end
  end

  # ── Private: per-file truncation ──

  @section_separator "\n### From:"

  defp truncate_per_file("", _max_per_file), do: {[], false}

  defp truncate_per_file(content, max_per_file) do
    sections = split_sections(content)

    Enum.map_reduce(sections, false, fn section, acc ->
      if String.length(section) <= max_per_file do
        {section, acc}
      else
        truncated = String.slice(section, 0, max_per_file)

        marker =
          "\n[TRUNCATED: exceeds #{max_per_file} chars per file]"

        {truncated <> marker, true}
      end
    end)
  end

  defp split_sections(content) do
    content
    |> String.split(@section_separator)
    |> Enum.with_index()
    |> Enum.map(fn
      {section, 0} -> section
      {section, _} -> @section_separator <> section
    end)
    |> Enum.reject(&(&1 == ""))
  end

  # ── Private: total truncation ──

  defp truncate_total(sections, max_total, already_truncated?) do
    result = do_truncate_total(sections, max_total)

    if result == sections and not already_truncated? do
      # Nothing was truncated — return the joined content
      Enum.join(sections)
    else
      truncated? = result != sections or already_truncated?

      if truncated? do
        joined = Enum.join(result)
        marker = "[TRUNCATED: total exceeds #{max_total} chars]"

        if byte_size(joined) == 0 and sections != [] do
          # All files were dropped — just return the marker
          marker
        else
          joined <> "\n" <> marker
        end
      else
        Enum.join(result)
      end
    end
  end

  defp do_truncate_total(sections, max_total) do
    # Keep highest-priority files (from the end), drop lower-priority ones
    # until total byte_size fits within max_total.
    # Reserve some space for the truncation marker.
    reserved = byte_size("[TRUNCATED: total exceeds 99999 chars]")

    Enum.reduce(Enum.reverse(sections), {[], 0}, fn section, {acc, total} ->
      section_bytes = byte_size(section)

      if total + section_bytes <= max_total - reserved do
        {[section | acc], total + section_bytes}
      else
        {acc, total}
      end
    end)
    |> elem(0)
  end
end

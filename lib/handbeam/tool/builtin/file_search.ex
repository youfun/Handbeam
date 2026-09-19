defmodule Handbeam.Tool.Builtin.FileSearch do
  @moduledoc """
  Fast fuzzy file search in the workspace using ExFff (ETS-based index).

  Replaces the fallback `rg`-based file search with an in-memory trigram index
  for millisecond-latency results. Uses frecency tracking to boost recently
  accessed files.

  ## Query Syntax

  - `"schema"` — fuzzy match terms (AND semantics, typo-tolerant)
  - `"*.ex"` — include patterns (file extension filter)
  - `"!test/"` — exclude patterns (paths containing this substring)
  - `"user controller"` — multi-term AND search
  - `"user *.ex !test/"` — combined: fuzzy + extension + exclusion
  """

  @behaviour Handbeam.Agent.Tool

  @impl true
  def name, do: "file_search"

  @impl true
  def description do
    "Fast fuzzy file search in the workspace. " <>
      "Supports typo-tolerant matching, file extension filters (e.g. *.ex), " <>
      "and path exclusions (e.g. !test/)."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        query: %{
          type: "string",
          description: "Search query with optional filters (e.g. 'user *.ex !test/')"
        },
        limit: %{type: "integer", description: "Max results to return", default: 20}
      },
      required: ["query"]
    }
  end

  @impl true
  def max_result_chars, do: 10_000

  @impl true
  def execute(%{"query" => query} = input, context) do
    limit = Map.get(input, "limit", 20)
    working_directory = Map.get(context, :working_directory)

    with {:ok, root} <- resolve_root(working_directory),
         {:ok, pid} <- ExFff.Index.ensure_started(root),
         {:ok, result} <- ExFff.Index.search(pid, query, limit: limit) do
      # Touch returned paths to update frecency
      for %{path: path} <- result.paths do
        ExFff.Index.touch(pid, path)
      end

      formatted = format_results(result)
      {:ok, formatted}
    end
  end

  def execute(_input, _context) do
    {:error, "query is required"}
  end

  # ── Helpers ──

  defp resolve_root(nil) do
    {:ok, File.cwd!()}
  end

  defp resolve_root(working_directory) do
    if File.dir?(working_directory) do
      {:ok, working_directory}
    else
      {:ok, File.cwd!()}
    end
  end

  defp format_results(%{paths: [], query: query, duration_ms: ms}) do
    "# No files found for: #{query} (#{ms}ms)"
  end

  defp format_results(%{paths: paths, query: query, duration_ms: ms}) do
    lines =
      paths
      |> Enum.with_index(1)
      |> Enum.map(fn {%{path: path, score: score}, i} ->
        "#{i}.\t#{path}\t(#{Float.round(score, 1)})"
      end)

    header = "# Found #{length(paths)} file(s) for: #{query} (#{ms}ms)\n"
    header <> Enum.join(lines, "\n")
  end
end

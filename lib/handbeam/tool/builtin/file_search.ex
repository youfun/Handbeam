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
        path: %{type: "string", description: "Workspace-relative directory prefix"},
        exclude: %{
          type: "array",
          items: %{type: "string"},
          description: "Path substrings to exclude"
        },
        cursor: %{type: "string", description: "Opaque next_cursor from a previous result"},
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
         {:ok, path} <- resolve_path_filter(root, input["path"]),
         {:ok, index} <- Handbeam.Search.ensure_started(root),
         {:ok, result} <-
           Handbeam.Search.search(index, query,
             limit: limit,
             path: path,
             exclude: List.wrap(input["exclude"] || []),
             cursor: input["cursor"],
             await: false
           ) do
      paths =
        Enum.filter(result.paths, fn %{path: path} ->
          Handbeam.Security.PathValidator.allowed_result?(root, path)
        end)

      {:ok, format_results(%{result | paths: paths})}
    end
  end

  def execute(_input, _context) do
    {:error, "query is required"}
  end

  # ── Helpers ──

  defp resolve_root(working_directory) when is_binary(working_directory) do
    cond do
      working_directory == "" ->
        {:error, "working_directory is required"}

      File.dir?(working_directory) ->
        {:ok, working_directory}

      true ->
        {:error, "working_directory is not a directory: #{working_directory}"}
    end
  end

  defp resolve_root(_working_directory) do
    {:error, "working_directory is required"}
  end

  defp resolve_path_filter(_root, nil), do: {:ok, nil}
  defp resolve_path_filter(_root, ""), do: {:ok, nil}

  defp resolve_path_filter(root, path) when is_binary(path) do
    expanded = if Path.type(path) == :absolute, do: path, else: Path.expand(path, root)

    case Handbeam.Security.PathValidator.validate_within_workspace(expanded, root) do
      :ok -> {:ok, Path.relative_to(expanded, root)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_path_filter(_root, _path), do: {:error, "path must be a string"}

  defp format_results(%{paths: [], query: query, duration_ms: ms} = result) do
    "# No files found for: #{query} (#{ms}ms)#{indexing_suffix(result)}"
  end

  defp format_results(%{paths: paths, query: query, duration_ms: ms} = result) do
    lines =
      paths
      |> Enum.with_index(1)
      |> Enum.map(fn {%{path: path, score: score} = entry, i} ->
        git = if entry[:git_status], do: "\t[git:#{entry.git_status}]", else: ""
        "#{i}.\t#{path}\t(#{Float.round(score, 1)})#{git}"
      end)

    continuation = if result[:cursor], do: "next_cursor: #{result.cursor}\n", else: ""

    header =
      continuation <>
        "# Found #{length(paths)} file(s) for: #{query} (#{ms}ms)#{indexing_suffix(result)}\n"

    header <> Enum.join(lines, "\n")
  end

  defp indexing_suffix(%{status: :indexing, indexed_count: count}),
    do: " — indexing (#{count} files scanned so far)"

  defp indexing_suffix(%{status: :indexing}), do: " — indexing"
  defp indexing_suffix(_result), do: ""
end

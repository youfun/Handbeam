defmodule Handbeam.Tool.Builtin.FileSearch do
  @moduledoc """
  Fast fuzzy file search in the workspace using ExFff (ETS-based index).

  Replaces the fallback `rg`-based file search with an in-memory trigram index
  for millisecond-latency results. Uses frecency tracking to boost recently
  accessed files.

  ## Query Syntax

  - `"schema"` — one or two filename fragments, not a sentence
  - `"*.ex"` — extension filter
  - `"sidebar*.heex"` — a `*` without `/` matches the file name only
  - `"desktop/**/*webview*"` — a glob containing `/` matches the relative path
  - `"!test/"` — exclude paths containing this substring
  - contents are not searched; use `grep`
  """

  @behaviour Handbeam.Agent.Tool

  @impl true
  def name, do: "file_search"

  @impl true
  def description do
    "Find files by 1–2 filename fragments, not a natural-language sentence. " <>
      "A `*` or `?` without `/` matches the file name only; include `/` or `**` to match the full relative path (for example desktop/**/*webview*). " <>
      "`*.ex` filters by extension. `!test/` excludes a path substring. " <>
      "Does not search file contents — use grep for that."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        query: %{
          type: "string",
          description:
            "1–2 filename fragments, an extension (`*.ex`), a path glob (`desktop/**/*webview*`), or an exclusion (`!test/`). Not a sentence, and not file contents."
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
    "# No files found for: #{query} (#{ms}ms)#{indexing_suffix(result)}\n" <>
      empty_hint(query, result)
  end

  defp format_results(%{paths: paths, query: query, duration_ms: ms} = result) do
    lines =
      paths
      |> Enum.with_index(1)
      |> Enum.map(&format_line/1)

    continuation = if result[:cursor], do: "next_cursor: #{result.cursor}\n", else: ""

    header =
      continuation <>
        partial_header(result) <>
        "# Found #{length(paths)} file(s) for: #{query} (#{ms}ms)#{indexing_suffix(result)}\n"

    header <> Enum.join(lines, "\n")
  end

  defp format_line({%{path: path} = entry, i}) do
    git = if entry[:git_status], do: "\t[git:#{entry.git_status}]", else: ""
    score = Map.get(entry, :match_score, entry.score)
    "#{i}.\t#{path}\t(#{Float.round(score, 1)})#{tier_tag(entry)}#{git}"
  end

  defp tier_tag(%{tier: tier}) when tier in [:exact, :filename, :path, :fuzzy], do: " [#{tier}]"
  defp tier_tag(_entry), do: ""

  defp partial_header(%{partial_match: %{matched: matched, total: total}})
       when is_integer(matched) and is_integer(total) do
    "partial match: #{matched}/#{total} terms\n"
  end

  defp partial_header(_result), do: ""

  defp empty_hint(query, result) do
    [indexed_hint(result), glob_hint(query), search_hint()]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp indexed_hint(%{indexed_count: count}) when is_integer(count), do: "Indexed #{count} files."
  defp indexed_hint(_result), do: ""

  defp glob_hint(query) when is_binary(query) do
    if basename_glob_query?(query) do
      "这是文件名 glob，不是路径 glob。A `*` without `/` matches the file name only, and that pattern was also tried against the full relative path."
    else
      ""
    end
  end

  defp glob_hint(_query), do: ""

  defp basename_glob_query?(query) do
    query
    |> ExFff.Query.parse()
    |> Map.get(:globs, [])
    |> Enum.any?(&(&1.basename? == true))
  end

  defp search_hint do
    "file_search matches file names and paths, not file contents — use grep for contents. Use 1–2 filename fragments, not a natural-language sentence."
  end

  defp indexing_suffix(%{status: :indexing, indexed_count: count}),
    do: " — indexing (#{count} files scanned so far)"

  defp indexing_suffix(%{status: :indexing}), do: " — indexing"
  defp indexing_suffix(_result), do: ""
end

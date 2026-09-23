defmodule Handbeam.Tool.Builtin.CodeSearch do
  @moduledoc """
  Locate code by symbol, path, or configured embeddings.

  Returns workspace-relative path and line numbers. File contents stay behind
  `read`. Without an embeddings config this is keyword search, not semantic
  search: a miss is not proof the code is absent. `index=partial` means the
  scan stopped at the budget.
  """

  @behaviour Handbeam.Agent.Tool

  alias Handbeam.CodeIndex
  alias Handbeam.WorkspaceStore

  @default_limit 10
  @max_limit 20

  @impl true
  def name, do: "code_search"

  @impl true
  def description do
    "Find code locations in the workspace by symbol, path, or meaning. " <>
      "Returns path and line numbers, not file contents; use read to inspect a hit. " <>
      "Without an embeddings config this is keyword/token search, not natural-language search. " <>
      "A keyword miss or index=partial does not mean the repository has no other matches. " <>
      "Use grep for exact text or regex."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Symbol, path fragment, or question"},
        limit: %{
          type: "integer",
          description: "Maximum hits",
          default: @default_limit
        },
        path: %{type: "string", description: "Optional workspace-relative directory prefix"},
        glob: %{type: "string", description: "Optional suffix filter such as .ex"}
      },
      required: ["query"]
    }
  end

  @impl true
  def max_result_chars, do: 8_000

  @impl true
  def concurrent?, do: true

  @impl true
  def execute(input, context) when is_map(input) do
    with {:ok, query} <- fetch_query(input),
         {:ok, root} <- workspace(context),
         {:ok, id} <- workspace_id(root, context) do
      parent = self()

      case CodeIndex.search(root, id, query, search_opts(input, context, parent)) do
        {:ok, payload} -> {:ok, format(payload, input), details(payload)}
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  def execute(_, _), do: {:error, "query is required"}

  defp search_opts(input, context, parent) do
    [
      limit: limit(input),
      path: blank_to_nil(input["path"] || input[:path]),
      glob: blank_to_nil(input["glob"] || input[:glob]),
      cancel: fn -> not Process.alive?(parent) end,
      models_file: context[:models_file]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp fetch_query(input) do
    query = input["query"] || input[:query]

    if is_binary(query) and String.trim(query) != "" do
      {:ok, String.trim(query)}
    else
      {:error, "query is required"}
    end
  end

  defp workspace(context) do
    root = context[:working_directory] || context["working_directory"] || File.cwd!()

    if File.dir?(root) do
      {:ok, Path.expand(root)}
    else
      {:error, "workspace not found"}
    end
  end

  defp workspace_id(root, context) do
    case context[:workspace_id] || context["workspace_id"] do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      _ ->
        case WorkspaceStore.get_by_path(root) do
          {:ok, %{"id" => id}} when is_binary(id) and id != "" -> {:ok, id}
          _ -> {:ok, "path-" <> hash_path(root)}
        end
    end
  end

  defp hash_path(root) do
    :crypto.hash(:sha256, root) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp limit(input) do
    case input["limit"] || input[:limit] do
      n when is_integer(n) -> n |> max(1) |> min(@max_limit)
      _ -> @default_limit
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp format(%{hits: hits, mode: mode, index: index, elapsed_ms: elapsed}, input) do
    filtered = filter_hits(hits, input)

    header =
      "# code_search  mode=#{mode}  index=#{index}  #{length(filtered)} hits  #{elapsed}ms"

    body =
      filtered
      |> Enum.with_index(1)
      |> Enum.map_join("\n", &format_hit/1)

    note =
      case mode do
        :keyword ->
          "Keyword mode matches symbols and tokens, not natural-language questions."

        :hybrid ->
          "Hybrid mode mixes keyword and embeddings. Use read to inspect a hit."
      end

    partial =
      if index == :ready do
        ""
      else
        "Partial or stale index means the scan stopped at the budget, not that the repo has no other hits."
      end

    [
      header,
      body,
      "Use read with offset/limit to inspect a hit. Do not treat this as file contents.",
      note,
      partial
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_hit({hit, n}) do
    symbol = if is_binary(hit.symbol) and hit.symbol != "", do: "  #{hit.symbol}", else: ""
    score = hit |> Map.get(:score, 0.0) |> Float.round(2)
    "#{n}. #{hit.path}:#{hit.start_line}-#{hit.end_line}#{symbol}  (#{score})"
  end

  defp filter_hits(hits, input) do
    path = input["path"] || input[:path]
    glob = input["glob"] || input[:glob]

    Enum.filter(hits, fn hit ->
      path_ok?(hit.path, path) and glob_ok?(hit.path, glob)
    end)
  end

  defp path_ok?(_hit, prefix) when prefix in [nil, ""], do: true

  defp path_ok?(hit, prefix) do
    normalized = prefix |> String.trim_leading("./") |> String.trim_trailing("/")
    hit == normalized or String.starts_with?(hit, normalized <> "/")
  end

  defp glob_ok?(_hit, glob) when glob in [nil, ""], do: true

  defp glob_ok?(hit, glob) do
    suffix = String.trim_leading(glob, "*")
    String.ends_with?(hit, suffix)
  end

  defp details(%{hits: hits}) do
    case hits do
      [hit | _] ->
        %{
          file_path: hit.path,
          start_line: hit.start_line,
          end_line: hit.end_line
        }

      _ ->
        %{}
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "code_search failed: #{inspect(reason)}"
end

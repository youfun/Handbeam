defmodule Handbeam.Tool.Extension.Beam.Sql do
  @moduledoc """
  Execute SQL through the app's Ecto repo.

  Results limited to 50 rows. Use to verify migrations, check data, introspect schema.
  """

  @behaviour Handbeam.Agent.Tool

  @max_rows 50

  @impl true
  def name, do: "ext__beam__sql"

  @impl true
  def description do
    "Execute SQL through the app's Ecto repo. Results limited to 50 rows. " <>
      "Use to verify migrations, check data, introspect schema."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "SQL query to execute"},
        repo: %{type: "string", description: "Ecto repo module name (default: first configured)"},
        params: %{
          type: "array",
          description: "Query parameters for parameterized queries",
          items: %{}
        }
      },
      required: ["query"]
    }
  end

  @impl true
  def execute(%{"query" => query}, context) do
    repo = Map.get(context, "repo") || default_repo()

    case repo do
      nil ->
        {:error, "No Ecto repo configured"}

      repo_mod ->
        execute_query(repo_mod, query)
    end
  end

  def execute(_input, _context) do
    {:error, "query is required"}
  end

  defp default_repo do
    # Try to find the primary Ecto repo from application config
    case Application.get_env(:handbeam, :ecto_repos) do
      [repo | _] -> repo
      _ -> nil
    end
  end

  defp execute_query(repo, query) do
    try do
      case repo.query(query, []) do
        {:ok, result} ->
          output =
            cond do
              is_map(result) and Map.has_key?(result, :columns) ->
                cols = result.columns
                rows = result.rows
                format_columns_rows(cols, rows)

              is_map(result) and Map.has_key?(result, :rows) ->
                rows = result.rows
                format_rows(rows)

              is_map(result) ->
                "Query result: #{inspect(result)}"

              true ->
                "Query result: #{inspect(result)}"
            end

          {:ok, output}

        {:error, error} ->
          {:error, "SQL error: #{inspect(error)}"}
      end
    rescue
      e ->
        {:error, "#{inspect(e.__struct__)}: #{Exception.message(e)}"}
    end
  end

  defp format_columns_rows(cols, rows) do
    formatted_rows =
      Enum.map(rows, fn row ->
        row_list = if is_tuple(row), do: Tuple.to_list(row), else: List.wrap(row)

        Enum.zip(cols, row_list)
        |> Map.new()
      end)

    format_results(formatted_rows)
  end

  defp format_rows(rows), do: format_results(rows)

  defp format_results(rows) do
    if rows == [] do
      "Query returned no rows."
    else
      # Extract column names from first row
      columns = Map.keys(hd(rows))

      display_rows =
        if length(rows) > @max_rows do
          Enum.take(rows, @max_rows)
        else
          rows
        end

      max_widths =
        Enum.reduce(columns, %{}, fn col, acc ->
          max_val =
            Enum.reduce(display_rows, 0, fn row, best ->
              val = Map.get(row, col)
              max(String.length(to_display_string(val)), best)
            end)

          Map.put(acc, col, max(max_val, String.length(col)))
        end)

      header =
        columns
        |> Enum.map_join(" | ", fn col ->
          String.pad_trailing(col, Map.get(max_widths, col, String.length(col)), " ")
        end)

      separator = String.duplicate("-", String.length(header))

      body =
        display_rows
        |> Enum.map(fn row ->
          columns
          |> Enum.map_join(" | ", fn col ->
            val = Map.get(row, col)
            String.pad_trailing(to_display_string(val), Map.get(max_widths, col, 0), " ")
          end)
        end)

      truncated_msg =
        if length(rows) > @max_rows do
          ["\n... (#{length(rows) - @max_rows} more rows not shown)"]
        else
          []
        end

      ([header, separator | body] ++ truncated_msg)
      |> Enum.join("\n")
    end
  end

  defp to_display_string(nil), do: "NULL"
  defp to_display_string(val) when is_binary(val), do: val
  defp to_display_string(val), do: inspect(val)
end

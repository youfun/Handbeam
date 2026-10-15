defmodule Handbeam.Tool.Extension.BeamSql do
  @moduledoc """
  Executes raw SQL through configured Ecto repositories.

  This tool can mutate application data and database schemas. It is deliberately
  excluded from the automatically enabled read-only extension set.
  """

  @behaviour Handbeam.Tool

  alias Handbeam.Tool.Extension.BeamDatabase
  alias Handbeam.ToolSpec

  @impl true
  def spec do
    ToolSpec.new!(%{
      id: "beam_sql",
      name: "ext__beam__sql",
      description:
        "Execute raw SQL through a configured Ecto Repo. This tool can mutate data and schemas and " <>
          "requires explicit authorization. The SQL dialect and parameter syntax are determined by " <>
          "the selected Repo; inspect ext__beam__db_schema first when unsure. Results are limited to 50 rows.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "SQL query to execute in the selected Repo's dialect"
          },
          "params" => %{
            "type" => "array",
            "description" => "Query parameters",
            "items" => %{}
          },
          "repo" => %{
            "type" => "string",
            "description" => "Ecto Repo module name; required when multiple repos are available"
          }
        },
        "required" => ["query"],
        "additionalProperties" => false
      }
    })
  end

  @impl true
  def execute(%{"query" => query} = args, _context) do
    with {:ok, repo_info} <- BeamDatabase.resolve_repo(args["repo"]),
         {:ok, result} <- BeamDatabase.query(repo_info, query, Map.get(args, "params", [])) do
      {:ok,
       BeamDatabase.format_metadata(repo_info) <>
         "\n\n" <> BeamDatabase.format_result(result)}
    else
      {:error, message} ->
        case BeamDatabase.resolve_repo(args["repo"]) do
          {:ok, repo_info} ->
            {:error, BeamDatabase.format_metadata(repo_info) <> "\n\nSQL error: " <> message}

          {:error, _repo_error} ->
            {:error, message}
        end
    end
  end

  def execute(_args, _context), do: {:error, "Missing required argument: query"}
end

defmodule Handbeam.Tool.Extension.BeamDatabase do
  @moduledoc false

  @query_timeout 15_000
  @row_limit 50
  @cell_limit 4_096

  @type repo_info :: %{
          application: atom(),
          repo: module(),
          repo_name: String.t(),
          adapter: module(),
          adapter_name: String.t(),
          dialect: String.t(),
          parameter_style: String.t(),
          running: boolean()
        }

  @spec list_repos() :: [repo_info()]
  def list_repos do
    Application.loaded_applications()
    |> Enum.flat_map(fn {application, _description, _version} ->
      application
      |> Application.get_env(:ecto_repos, [])
      |> List.wrap()
      |> Enum.map(&{application, &1})
    end)
    |> Enum.uniq_by(fn {_application, repo} -> repo end)
    |> Enum.flat_map(fn {application, repo} ->
      case repo_info(application, repo) do
        {:ok, info} -> [info]
        :error -> []
      end
    end)
    |> Enum.sort_by(& &1.repo_name)
  end

  @spec resolve_repo(String.t() | nil) :: {:ok, repo_info()} | {:error, String.t()}
  def resolve_repo(repo_name) do
    repos = list_repos()

    case {repo_name, repos} do
      {nil, [repo]} ->
        {:ok, repo}

      {nil, []} ->
        {:error, "No Ecto repositories are configured in the loaded applications"}

      {nil, repos} ->
        names = Enum.map_join(repos, ", ", & &1.repo_name)
        {:error, "Multiple Ecto repositories are available; choose one with repo: #{names}"}

      {name, repos} when is_binary(name) ->
        case Enum.find(repos, &(&1.repo_name == name)) do
          nil ->
            names = Enum.map_join(repos, ", ", & &1.repo_name)
            {:error, "Unknown Ecto repository #{inspect(name)}. Available repositories: #{names}"}

          repo ->
            {:ok, repo}
        end
    end
  end

  @spec query(repo_info(), String.t(), list()) ::
          {:ok, map()} | {:error, String.t()}
  def query(repo_info, query, params) do
    try do
      case repo_info.repo.query(query, params, timeout: @query_timeout) do
        {:ok, result} -> {:ok, result}
        {:error, error} -> {:error, Exception.message(error)}
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      :exit, reason -> {:error, "Repo query exited: #{inspect(reason, limit: 20)}"}
    end
  end

  @spec result_rows(map()) :: {[map()], boolean()}
  def result_rows(result) do
    columns = Enum.map(result.columns || [], &to_string/1)
    rows = result.rows || []
    limited_rows = Enum.take(rows, @row_limit)

    mapped =
      Enum.map(limited_rows, fn row ->
        columns
        |> Enum.zip(row)
        |> Map.new(fn {column, value} -> {column, json_value(value)} end)
      end)

    {mapped, length(rows) > @row_limit}
  end

  @spec metadata(repo_info()) :: map()
  def metadata(repo_info) do
    %{
      "application" => Atom.to_string(repo_info.application),
      "repo" => repo_info.repo_name,
      "adapter" => repo_info.adapter_name,
      "dialect" => repo_info.dialect,
      "parameter_style" => repo_info.parameter_style,
      "running" => repo_info.running
    }
  end

  @spec format_metadata(repo_info()) :: String.t()
  def format_metadata(repo_info) do
    [
      "Repo: #{repo_info.repo_name}",
      "Adapter: #{repo_info.adapter_name}",
      "Dialect: #{repo_info.dialect}",
      "Parameter style: #{repo_info.parameter_style}"
    ]
    |> Enum.join("\n")
  end

  @spec format_result(map()) :: String.t()
  def format_result(%{columns: nil, num_rows: count}) do
    "Query completed. #{count} row(s) affected."
  end

  def format_result(%{columns: columns, rows: rows}) when is_list(columns) do
    columns = Enum.map(columns, &markdown_cell/1)
    visible_rows = Enum.take(rows || [], @row_limit)
    header = "| " <> Enum.join(columns, " | ") <> " |"
    separator = "| " <> Enum.map_join(columns, " | ", fn _ -> "---" end) <> " |"

    body =
      Enum.map(visible_rows, fn row ->
        "| " <> Enum.map_join(row, " | ", &markdown_cell/1) <> " |"
      end)

    suffix =
      if length(rows || []) > @row_limit do
        ["", "Results truncated to #{@row_limit} rows."]
      else
        []
      end

    Enum.join([header, separator] ++ body ++ suffix, "\n")
  end

  def format_result(result), do: inspect(result, limit: 50, printable_limit: @cell_limit)

  @spec dialect(module()) :: {String.t(), String.t()}
  def dialect(adapter) do
    case inspect(adapter) do
      "Ecto.Adapters.SQLite3" -> {"sqlite", "?"}
      "Ecto.Adapters.Postgres" -> {"postgresql", "$1, $2, ..."}
      "Ecto.Adapters.MyXQL" -> {"mysql", "?"}
      "Ecto.Adapters.Tds" -> {"sql_server", "@1, @2, ..."}
      _other -> {"unknown", "adapter-specific"}
    end
  end

  defp repo_info(application, repo) when is_atom(repo) do
    with {:module, _module} <- Code.ensure_loaded(repo),
         true <- function_exported?(repo, :__adapter__, 0),
         adapter when is_atom(adapter) <- repo.__adapter__() do
      {dialect, parameter_style} = dialect(adapter)

      {:ok,
       %{
         application: application,
         repo: repo,
         repo_name: inspect(repo),
         adapter: adapter,
         adapter_name: inspect(adapter),
         dialect: dialect,
         parameter_style: parameter_style,
         running: is_pid(Process.whereis(repo))
       }}
    else
      _other -> :error
    end
  end

  defp repo_info(_application, _repo), do: :error

  defp json_value(nil), do: nil
  defp json_value(value) when is_boolean(value) or is_number(value), do: value
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)

  defp json_value(value) when is_binary(value) do
    if String.valid?(value) do
      truncate_string(value)
    else
      encoded = value |> binary_part(0, min(byte_size(value), div(@cell_limit, 2))) |> Base.encode16()
      suffix = if byte_size(value) > div(@cell_limit, 2), do: "…", else: ""
      "0x" <> encoded <> suffix
    end
  end

  defp json_value(%Date{} = value), do: Date.to_iso8601(value)
  defp json_value(%Time{} = value), do: Time.to_iso8601(value)
  defp json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp json_value(value) do
    value
    |> inspect(limit: 50, printable_limit: @cell_limit)
    |> truncate_string()
  end

  defp markdown_cell(value) do
    value
    |> json_value()
    |> case do
      nil -> "NULL"
      normalized when is_binary(normalized) -> normalized
      normalized -> to_string(normalized)
    end
    |> String.replace("\\", "\\\\")
    |> String.replace("|", "\\|")
    |> String.replace("\r", "\\r")
    |> String.replace("\n", "\\n")
  end

  defp truncate_string(value) do
    if String.length(value) > @cell_limit do
      String.slice(value, 0, @cell_limit) <> "…"
    else
      value
    end
  end
end

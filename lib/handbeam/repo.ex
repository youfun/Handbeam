defmodule Handbeam.Repo do
  use Ecto.Repo,
    otp_app: :handbeam,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    config =
      case Handbeam.Host.get(:data_dir) do
        dir when is_binary(dir) and dir != "" ->
          if configured_database?(config),
            do: config,
            else: Keyword.put(config, :database, Path.join(dir, "handbeam.db"))

        _ ->
          config
      end

    {:ok, config}
  end

  # Dev sets both data_dir and an explicit database. Packaged hosts set only
  # data_dir and expect handbeam.db beside it.
  defp configured_database?(config) do
    case Keyword.get(config, :database) do
      path when is_binary(path) and path != "" -> true
      _ -> false
    end
  end
end

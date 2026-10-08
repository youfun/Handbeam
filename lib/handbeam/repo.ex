defmodule Handbeam.Repo do
  use Ecto.Repo,
    otp_app: :handbeam,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    config =
      case Handbeam.Host.get(:data_dir) do
        dir when is_binary(dir) and dir != "" ->
          Keyword.put(config, :database, Path.join(dir, "handbeam.db"))

        _ ->
          config
      end

    {:ok, config}
  end
end

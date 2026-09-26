defmodule Handbeam.Repo do
  use Ecto.Repo,
    otp_app: :handbeam,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    config =
      if Handbeam.Host.configured?() do
        Keyword.put(config, :database, Path.join(Handbeam.Host.data_dir(), "handbeam.db"))
      else
        config
      end

    {:ok, config}
  end
end

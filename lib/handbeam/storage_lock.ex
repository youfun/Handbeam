defmodule Handbeam.StorageLock do
  @moduledoc """
  Holds the single-runtime native lock for the configured Handbeam database.

  The sidecar belongs to the resolved database path, not to its parent data
  directory, so another independent SQLite database in the same host container
  does not share this ownership boundary.
  """

  use GenServer

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc false
  def lock_path(database_path), do: Path.expand(database_path) <> ".lock"

  @impl true
  def init(opts) do
    database_path = Keyword.get_lazy(opts, :database, &Handbeam.Repo.database_path/0)
    lock_path = lock_path(database_path)

    with :ok <- File.mkdir_p(Path.dirname(lock_path)),
         {:ok, resource} <- :handbeam_storage.lock(lock_path) do
      {:ok, %{resource: resource}}
    else
      {:error, :locked} -> {:stop, :database_locked}
      {:error, reason} -> {:stop, {:database_lock_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{resource: resource}) do
    :handbeam_storage.close(resource)
    :ok
  end
end

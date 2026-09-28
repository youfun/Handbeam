defmodule Handbeam.Search.ExFffBackend do
  @moduledoc false

  @behaviour Handbeam.Search.Backend

  @impl true
  def ensure_started(workspace) do
    with {:ok, index} <- ExFff.Index.ensure_started(workspace) do
      Handbeam.Search.Watcher.watch(workspace, index)
      {:ok, index}
    end
  end

  @impl true
  def search(index, query, opts), do: ExFff.Index.search(index, query, opts)

  @impl true
  def files(index, opts), do: ExFff.Index.files(index, opts)

  @impl true
  def touch(index, path), do: ExFff.Index.touch(index, path)

  @impl true
  def update_paths(index, paths), do: ExFff.Index.update_paths(index, paths)

  @impl true
  def set_git_status(index, entries), do: ExFff.Index.set_git_status(index, entries)
end

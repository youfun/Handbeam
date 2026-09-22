defmodule Handbeam.CodeIndex do
  @moduledoc """
  Workspace code index facade.

  Keyword search is always local (SQLite FTS5). Semantic search runs only when
  `models.json` has an `embeddings` section. This module does not start an index
  at application boot and does not call `Handbeam.Git`.
  """

  alias Handbeam.CodeIndex.{Embedder, Location, Scan, Search, Store, Sync}

  @sync_budget_ms 8_000
  @vector_scan_limit 256
  @vector_budget_ms 1_500

  @type status :: :ready | :partial | :stale

  @doc """
  Resolve where this workspace's index lives.

  Imported and unwritable roots go to `Host.data_dir()`. A writable private or
  desktop workspace uses `<workspace>/.handbeam/code-index/`.
  """
  @spec index_dir(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def index_dir(workspace_root, workspace_id) when is_binary(workspace_id) do
    Location.resolve(workspace_root, workspace_id)
  end

  @doc """
  Open or create the index, then sync until the budget.

  Returns the open store. The caller must `Store.close/1`.
  """
  @spec ensure_index(Path.t(), String.t(), keyword()) ::
          {:ok, Store.t(), map()} | {:error, term()}
  def ensure_index(workspace_root, workspace_id, opts \\ []) do
    budget = Keyword.get(opts, :budget_ms, @sync_budget_ms)

    with {:ok, dir} <- Location.resolve(workspace_root, workspace_id),
         {:ok, store} <- Store.open(dir, workspace_root, workspace_id) do
      outcome =
        Sync.sync(store, workspace_root, budget, Keyword.put(opts, :workspace_id, workspace_id))

      maybe_embed(store, opts)
      {:ok, store, Map.put(outcome, :index_dir, dir)}
    end
  end

  @doc """
  Search a workspace. Syncs under the budget, then queries FTS and optional vectors.
  """
  @spec search(Path.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def search(workspace_root, workspace_id, query, opts \\ []) when is_binary(query) do
    started = System.monotonic_time(:millisecond)
    limit = opts |> Keyword.get(:limit, 10) |> clamp_limit()

    with {:ok, store, sync} <- ensure_index(workspace_root, workspace_id, opts) do
      try do
        mode = search_mode(opts)
        hits = Search.query(store, query, limit, search_opts(opts, mode))
        elapsed = System.monotonic_time(:millisecond) - started

        {:ok,
         %{
           hits: hits,
           mode: mode,
           index: sync.status,
           elapsed_ms: elapsed,
           truncated: sync.status != :ready
         }}
      after
        Store.close(store)
      end
    end
  end

  @doc "Index freshness without scanning. Does not create a database."
  @spec status(Path.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def status(workspace_root, workspace_id) do
    with {:ok, dir} <- Location.resolve(workspace_root, workspace_id) do
      path = Path.join(dir, "index.sqlite")

      if File.exists?(path) do
        case Store.open(dir, workspace_root, workspace_id) do
          {:ok, store} ->
            try do
              {:ok, Map.merge(%{exists: true, dir: dir}, Store.meta_status(store))}
            after
              Store.close(store)
            end

          {:error, :identity_mismatch} ->
            {:ok, %{exists: true, dir: dir, identity: :mismatch}}

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:ok, %{exists: false, dir: dir}}
      end
    end
  end

  @doc "True when models.json has a usable embeddings section. Does not read the key."
  @spec embeddings_configured?(keyword()) :: boolean()
  def embeddings_configured?(opts \\ []) do
    match?({:ok, _}, Embedder.HTTP.config(opts))
  end

  defp search_mode(opts) do
    cond do
      Keyword.get(opts, :mode) == :keyword -> :keyword
      Keyword.get(opts, :mode) == :hybrid -> :hybrid
      Keyword.get(opts, :embedder) == Handbeam.CodeIndex.Embedder.Noop -> :keyword
      embeddings_configured?(opts) -> :hybrid
      true -> :keyword
    end
  end

  defp search_opts(opts, :keyword) do
    Keyword.merge(opts,
      mode: :keyword,
      vector_scan_limit: 0,
      vector_budget_ms: 0
    )
  end

  defp search_opts(opts, :hybrid) do
    Keyword.merge(
      [
        mode: :hybrid,
        vector_scan_limit: @vector_scan_limit,
        vector_budget_ms: @vector_budget_ms,
        embedder: Embedder.HTTP
      ],
      opts
    )
  end

  defp maybe_embed(store, opts) do
    embedder = Keyword.get(opts, :embedder, Embedder.Noop)

    with :hybrid <- search_mode(opts),
         {:ok, config} <- embedder.config(opts) do
      pending = Store.chunks_pending_embed(store, config.model, 8)

      case embedder.embed(Enum.map(pending, &embed_text/1), config) do
        {:ok, vectors} ->
          Enum.zip(pending, vectors)
          |> Enum.each(fn {chunk, vector} ->
            {blob, dim} = Embedder.HTTP.pack(vector)
            Store.put_embedding(store, chunk.id, config.model, dim, blob)
          end)

        _ ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  defp embed_text(chunk) do
    prefix = "[#{chunk.kind}] #{chunk.path}::#{chunk.symbol}"
    prefix <> "\n" <> String.slice(chunk.text, 0, 2_000)
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(20)
  defp clamp_limit(_), do: 10

  @doc false
  def scan_files(root, opts \\ []), do: Scan.list(root, opts)
end

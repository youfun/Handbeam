defmodule Handbeam.Memory.MemoryStore do
  @moduledoc """
  Memory store — CRUD operations for engrams and synapses.

  Provides recall (search), learn (create), reinforce (strengthen),
  and associate (link) operations.
  """

  import Ecto.Query, warn: false

  alias Handbeam.Memory.{Engram, Synapse}
  alias Handbeam.Repo

  @doc """
  Recall engrams matching a query.

  Searches content with ILIKE for fuzzy matching. Returns results
  ordered by reinforcement strength (long-term first, then recency).

  ## Examples

      iex> MemoryStore.recall("project structure")
      [%Engram{}, ...]
  """
  @spec recall(String.t(), keyword()) :: [Engram.t()]
  def recall(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    pattern = "%#{query}%"

    Engram
    |> where([e], like(fragment("lower(?)", e.content), ^String.downcase(pattern)))
    |> where([e], is_nil(e.expires_at) or e.expires_at > ^DateTime.utc_now())
    |> apply_scope_filter(opts)
    |> order_by([e], asc: e.short_term, desc: e.reinforced_count, desc: e.updated_at)
    |> limit(^limit)
    |> preload([:source_synapses, :target_synapses])
    |> Repo.all()
  end

  @doc """
  Return memory recall metrics for a query without loading full associations.

  Metrics are intended for evaluating Observational Memory effectiveness and
  isolation behaviour: hit counts, workspace/global mix, and scoped leakage.
  """
  @spec recall_metrics(String.t(), keyword()) :: map()
  def recall_metrics(query, opts \\ []) do
    results = recall(query, opts)
    workspace_id = Keyword.get(opts, :workspace_id)

    %{
      query: query,
      total_hits: length(results),
      workspace_hits: Enum.count(results, &(metadata_value(&1, "scope") == "workspace")),
      global_hits: Enum.count(results, &(metadata_value(&1, "scope") == "global")),
      current_workspace_hits:
        Enum.count(results, fn engram ->
          metadata_value(engram, "scope") == "workspace" and
            metadata_value(engram, "workspace_id") == workspace_id
        end),
      cross_workspace_hits:
        Enum.count(results, fn engram ->
          metadata_value(engram, "scope") == "workspace" and
            not is_nil(workspace_id) and metadata_value(engram, "workspace_id") != workspace_id
        end)
    }
  end

  @doc """
  Learn a new engram.

  ## Examples

      iex> MemoryStore.learn("User prefers snake_case", :preference)
      {:ok, %Engram{}}
  """
  @spec learn(String.t(), atom(), keyword()) :: {:ok, Engram.t()} | {:error, Ecto.Changeset.t()}
  def learn(content, kind, opts \\ []) do
    %Engram{}
    |> Engram.changeset(%{
      content: content,
      kind: kind,
      short_term: Keyword.get(opts, :short_term, true),
      metadata: Keyword.get(opts, :metadata, %{})
    })
    |> Repo.insert()
  end

  @doc """
  Reinforce an engram — promote from short-term to long-term memory.

  Increments the reinforcement counter and updates the timestamp.
  """
  @spec reinforce(Engram.t()) :: {:ok, Engram.t()} | {:error, Ecto.Changeset.t()}
  def reinforce(%Engram{} = engram) do
    engram
    |> Engram.changeset(%{
      short_term: false,
      expires_at: nil,
      reinforced_count: engram.reinforced_count + 1,
      last_reinforced_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @doc """
  Create a synapse between two engrams.
  """
  @spec associate(Engram.t(), Engram.t(), atom()) ::
          {:ok, Synapse.t()} | {:error, Ecto.Changeset.t()}
  def associate(%Engram{id: source_id}, %Engram{id: target_id}, kind) do
    %Synapse{}
    |> Synapse.changeset(%{source_id: source_id, target_id: target_id, kind: kind})
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc """
  Clean up expired short-term engrams.
  """
  @spec cleanup_expired() :: {integer(), nil}
  def cleanup_expired do
    {count, _} =
      from(e in Engram, where: e.short_term == true and e.expires_at < ^DateTime.utc_now())
      |> Repo.delete_all()

    {count, nil}
  end

  # ── Scope / Privacy Filtering ──

  defp apply_scope_filter(query, opts) do
    memory_scope = normalize_scope(Keyword.get(opts, :memory_scope))
    privacy_mode = normalize_privacy_mode(Keyword.get(opts, :privacy_mode))
    workspace_id = Keyword.get(opts, :workspace_id)

    cond do
      privacy_mode == :local_only and is_binary(workspace_id) ->
        where_workspace(query, workspace_id)

      memory_scope == :workspace and is_binary(workspace_id) ->
        where_workspace(query, workspace_id)

      memory_scope == :global ->
        where_global(query)

      memory_scope == :both and is_binary(workspace_id) ->
        where_workspace_or_global(query, workspace_id)

      true ->
        query
    end
  end

  defp where_workspace(query, workspace_id) do
    where(
      query,
      [e],
      fragment("json_extract(?, '$.scope')", e.metadata) == "workspace" and
        fragment("json_extract(?, '$.workspace_id')", e.metadata) == ^workspace_id
    )
  end

  defp where_global(query) do
    where(query, [e], fragment("json_extract(?, '$.scope')", e.metadata) == "global")
  end

  defp where_workspace_or_global(query, workspace_id) do
    where(
      query,
      [e],
      fragment("json_extract(?, '$.scope')", e.metadata) == "global" or
        (fragment("json_extract(?, '$.scope')", e.metadata) == "workspace" and
           fragment("json_extract(?, '$.workspace_id')", e.metadata) == ^workspace_id)
    )
  end

  defp normalize_scope(scope) when scope in [:global, :workspace, :both], do: scope

  defp normalize_scope(scope) when scope in ["global", "workspace", "both"],
    do: String.to_existing_atom(scope)

  defp normalize_scope(_), do: nil

  defp normalize_privacy_mode(mode) when mode in [:standard, :local_only], do: mode
  defp normalize_privacy_mode("standard"), do: :standard
  defp normalize_privacy_mode("local_only"), do: :local_only
  defp normalize_privacy_mode(_), do: nil

  defp metadata_value(%Engram{metadata: metadata}, key), do: metadata_value(metadata, key)

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Handbeam.Utils.SafeMap.get(metadata, key)

  defp metadata_value(_, _), do: nil
end

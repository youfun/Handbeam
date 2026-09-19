defmodule Handbeam.Tool.Memory.MemRecall do
  @moduledoc """
  Memory recall tool — searches engrams by query.

  Part of the memory toolset: recall / learn / reinforce / associate.
  """

  @behaviour Handbeam.Agent.Tool

  @impl true
  def name, do: "mem_recall"

  @impl true
  def description do
    "Search your memory for relevant facts, patterns, and preferences. " <>
      "Use before making assumptions about the user or project."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Search query for memory recall"},
        limit: %{type: "integer", description: "Max results", default: 10}
      },
      required: ["query"]
    }
  end

  @impl true
  def max_result_chars, do: 5_000

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"query" => query} = input, context) do
    limit = Map.get(input, "limit", 10)
    results = Handbeam.Memory.MemoryStore.recall(query, recall_opts(context, limit))

    if results == [] do
      {:ok, "No memories found."}
    else
      formatted =
        results
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {engram, idx} ->
          """
          #{idx}. <stored-knowledge id="#{engram.id}" kind="#{engram.kind}" scope="#{scope(engram)}">
          #{engram.content}
          </stored-knowledge>
          """
        end)

      {:ok, formatted, %{count: length(results), results: results}}
    end
  end

  def execute(_input, _context), do: {:error, "query is required"}

  defp scope(%{short_term: true}), do: "short-term"

  defp scope(%{metadata: %{} = metadata}) do
    Map.get(metadata, "scope") || Map.get(metadata, :scope) || "long-term"
  end

  defp scope(_engram), do: "long-term"

  defp recall_opts(context, limit) when is_map(context) do
    [
      limit: limit,
      workspace_id: context_value(context, :workspace_id),
      memory_scope: context_value(context, :memory_scope),
      privacy_mode: context_value(context, :privacy_mode)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp recall_opts(_context, limit), do: [limit: limit]

  defp context_value(context, key),
    do: Map.get(context, key) || Map.get(context, Atom.to_string(key))
end

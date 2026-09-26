defmodule Handbeam.Agent.Provider do
  @moduledoc """
  Behaviour for LLM providers.

  Each provider translates between its native wire format and
  `Handbeam.Agent.Message` structs.

  Usage preserves provider-native `input_tokens` and `output_tokens` counts.
  `total_input_tokens` includes uncached input, cache reads and cache writes
  exactly once, so consumers can compare cache usage across providers.
  """

  alias Handbeam.Agent.Message

  @type tool_def :: %{name: String.t(), description: String.t(), input_schema: map()}

  @type completion_response :: %{
          required(:stop_reason) => :tool_use | :end_turn,
          required(:messages) => [Message.t()],
          required(:usage) => map(),
          optional(:provider_state) => map(),
          optional(:response_metadata) => map()
        }

  @doc """
  Send messages to the provider and get a completion response.

  Returns `{:ok, completion_response()}` on success or `{:error, term()}`.
  """
  @callback complete(
              messages :: [Message.t()],
              tool_defs :: [tool_def()],
              config :: map()
            ) :: {:ok, completion_response()} | {:error, term()}

  @doc """
  Stream a completion, calling `on_chunk` for each text delta.

  Returns the same `{:ok, completion_response()}` once the stream finishes.
  """
  @callback stream(
              messages :: [Message.t()],
              tool_defs :: [tool_def()],
              config :: map(),
              on_chunk :: (String.t() -> :ok)
            ) :: {:ok, completion_response()} | {:error, term()}

  @optional_callbacks [stream: 4]

  # ── Shared Helpers (used by provider implementations) ──────────────

  @doc """
  Normalizes Responses and Chat Completions usage without counting cache reads twice.

  ## Examples

      iex> Handbeam.Agent.Provider.openai_usage(%{"prompt_tokens" => 100, "prompt_tokens_details" => %{"cached_tokens" => 80}})
      %{input_tokens: 100, total_input_tokens: 100, output_tokens: 0, cache_read_input_tokens: 80}
  """
  def openai_usage(usage) do
    input = usage["input_tokens"] || usage["prompt_tokens"] || 0
    details = usage["input_tokens_details"] || usage["prompt_tokens_details"] || %{}

    %{
      input_tokens: input,
      total_input_tokens: input,
      output_tokens: usage["output_tokens"] || usage["completion_tokens"] || 0,
      cache_read_input_tokens: details["cached_tokens"] || usage["prompt_cache_hit_tokens"] || 0
    }
  end

  @doc """
  Recursively convert atom keys to strings in maps.

  Used by providers to prepare JSON-compatible request bodies.
  """
  @spec stringify_keys(term()) :: term()
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) ->
        {Atom.to_string(k), stringify_keys(v)}

      {k, v} when is_binary(k) ->
        {k, stringify_keys(v)}

      {k, _v} ->
        raise ArgumentError, "stringify_keys expects atom or string keys, got: #{inspect(k)}"
    end)
  end

  def stringify_keys(map) when is_list(map), do: Enum.map(map, &stringify_keys/1)
  def stringify_keys(map), do: map

  @doc """
  Decode a JSON binary response body, passing through maps unchanged.

  Returns `{:ok, decoded_map}` or `{:error, reason}`.
  """
  @spec decode_body(binary() | map()) :: {:ok, map()} | {:error, String.t()}
  def decode_body(body) when is_map(body), do: {:ok, body}

  def decode_body(body) when is_binary(body) do
    case Handbeam.JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, "Failed to decode response JSON"}
    end
  end
end

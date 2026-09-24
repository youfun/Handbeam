defmodule Handbeam.Agent.Provider.Cursor.Models do
  @moduledoc """
  Discovers usable Cursor models via unary `GetUsableModels`.

  Failures are explicit. This never falls back to another provider or a
  hard-coded substitute model. Cost is the upstream vendor price from llm_db
  when the id maps to one; otherwise it is omitted, never written as 0.
  """

  alias Handbeam.Agent.Auth.CursorCredential
  alias Handbeam.Agent.Provider.Cursor.{Proto, Transport}
  alias Handbeam.LlmDbDefaults

  @preferred "composer-2.5"

  @spec discover(keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def discover(opts \\ []) do
    provider_id = Keyword.get(opts, :provider_id, "cursor")

    with {:ok, %{api_key: token}} <- CursorCredential.resolve_transport_key(provider_id, opts),
         {:ok, body} <- fetch_models(token, opts),
         models when models != [] <- Proto.decode_models_response(body) do
      {:ok, Enum.map(models, &to_catalog/1)}
    else
      [] -> {:error, "Cursor returned no usable models for this account."}
      {:error, :not_found} -> {:error, "Sign in with a Cursor subscription to connect."}
      {:error, message} when is_binary(message) -> {:error, classify(message)}
      {:error, message} -> {:error, classify(inspect(message))}
    end
  end

  @spec preferred_id([map()]) :: String.t() | nil
  def preferred_id(models) do
    ids = Enum.map(models, & &1["id"])

    cond do
      @preferred in ids -> @preferred
      true -> List.first(ids)
    end
  end

  defp fetch_models(token, opts) do
    transport_mod = Keyword.get(opts, :transport_mod, Transport)

    with {:ok, transport} <- transport_mod.connect(Keyword.get(opts, :transport_opts, [])),
         {:ok, transport, body} <- transport_mod.get_usable_models(transport, token, opts) do
      _ = transport_mod.close(transport)
      {:ok, body}
    else
      {:error, reason} ->
        {:error, to_string_reason(reason)}

      {:error, transport, reason} ->
        _ = transport_mod.close(transport)
        {:error, to_string_reason(reason)}
    end
  end

  defp to_catalog(model) do
    context_window = default_context_window(model.id)

    %{
      "id" => model.id,
      "name" => display_name(model, context_window),
      "reasoning" => model.thinking?,
      "input" => ["text"],
      "contextWindow" => context_window,
      "maxTokens" => 32_000
    }
    |> maybe_put_cost(LlmDbDefaults.price_for_model_id(model.id))
  end

  defp maybe_put_cost(catalog, nil), do: catalog
  defp maybe_put_cost(catalog, cost), do: Map.put(catalog, "cost", cost)

  defp display_name(%{name: name}, context_window) when is_binary(name) and name != "" do
    String.replace(name, ~r/\b1M\b/, format_context(context_window))
  end

  defp display_name(%{id: id}, _context_window), do: id

  # GetUsableModels does not include token limits. Cursor's catalog names advertise
  # the optional 1M maximum, while a normal Run request uses the documented default.
  defp default_context_window(id) do
    cond do
      String.starts_with?(id, ["claude-opus-5", "claude-opus-4-8", "claude-fable-5"]) ->
        300_000

      String.starts_with?(id, "claude-opus-4-7") and not String.ends_with?(id, "-fast") ->
        300_000

      String.starts_with?(id, ["gpt-", "codex-"]) ->
        272_000

      String.contains?(id, "grok-4") ->
        256_000

      String.starts_with?(id, "kimi-k2.7") ->
        262_144

      String.starts_with?(id, "muse-spark") ->
        300_000

      id == "default" ->
        128_000

      true ->
        200_000
    end
  end

  defp format_context(262_144), do: "262K"
  defp format_context(tokens), do: "#{div(tokens, 1_000)}K"

  defp classify(message) do
    down = String.downcase(message)

    cond do
      String.contains?(down, "429") or String.contains?(down, "rate") ->
        "Cursor rate limited this account. Try again later."

      String.contains?(down, "401") or String.contains?(down, "403") or
          String.contains?(down, "expired") ->
        "Cursor subscription expired. Sign in with Cursor to reconnect."

      String.contains?(down, "no usable") ->
        message

      true ->
        "Cursor model discovery failed: #{message}"
    end
  end

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: inspect(reason)
end

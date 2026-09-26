defmodule Handbeam.Agent.Provider.Codex.Models do
  @moduledoc "Authenticated Codex catalog; never uses the Platform API model list."

  alias Handbeam.Agent.Auth.CodexCredential
  alias Handbeam.Agent.Provider.Codex

  # Codex filters /models by this query param. 0.1.0 is below every current
  # minimal_client_version, so the backend returns no visible models.
  # Keep this at or above the newest bundled Codex CLI catalog requirement.
  @client_version "0.156.1"

  def discover(opts \\ []) do
    with {:ok, auth} <- CodexCredential.resolve_transport_key("openai_codex", opts) do
      req =
        Keyword.get(
          opts,
          :req_module,
          Application.get_env(:handbeam, :codex_models_req_module, Req)
        )

      headers = List.keyreplace(Codex.headers(auth), "accept", 0, {"accept", "application/json"})

      case req.get("https://chatgpt.com/backend-api/codex/models",
             headers: headers,
             params: [client_version: @client_version],
             retry: false,
             redirect: false,
             receive_timeout: 10_000,
             connect_options: [timeout: 10_000]
           ) do
        {:ok, %{status: 200, body: %{"models" => models}}} when is_list(models) ->
          parse_models(models)

        {:ok, %{status: status}} ->
          {:error,
           "Codex model discovery failed (HTTP #{status}). The existing model list was kept."}

        {:error, _} ->
          {:error, "Codex model discovery unavailable. The existing model list was kept."}
      end
    end
  end

  defp parse_models(models) do
    visible =
      Enum.flat_map(models, fn
        %{"slug" => id} = model when is_binary(id) and id != "" ->
          if model["visibility"] == "hide" do
            []
          else
            [catalog_model(id, model)]
          end

        _ ->
          []
      end)

    case visible do
      [] -> {:error, "No Codex models were returned. The existing model list was kept."}
      _ -> {:ok, Enum.uniq_by(visible, & &1["id"])}
    end
  end

  defp catalog_model(id, model) do
    levels = reasoning_levels(model["supported_reasoning_levels"])

    %{
      "id" => id,
      "name" => model["display_name"] || id,
      "reasoning" => levels != [],
      "input" => model["input_modalities"] || ["text"],
      "contextWindow" => model["context_window"]
    }
    |> maybe_put("reasoningLevels", levels)
    |> maybe_put("defaultReasoning", model["default_reasoning_level"])
  end

  defp reasoning_levels(levels) when is_list(levels) do
    levels
    |> Enum.flat_map(fn
      %{"effort" => effort} when is_binary(effort) and effort != "" -> [effort]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp reasoning_levels(_), do: []

  defp maybe_put(model, _key, value) when value in [nil, ""], do: model
  defp maybe_put(model, _key, []), do: model
  defp maybe_put(model, key, value), do: Map.put(model, key, value)
end

defmodule Handbeam.Agent.Provider.Codex.Models do
  @moduledoc "Authenticated Codex catalog; never uses the Platform API model list."

  alias Handbeam.Agent.Auth.CodexCredential
  alias Handbeam.Agent.Provider.Codex

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
             params: [client_version: "0.1.0"],
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
            [
              %{
                "id" => id,
                "name" => model["display_name"] || id,
                "reasoning" => (model["supported_reasoning_levels"] || []) != [],
                "input" => model["input_modalities"] || ["text"],
                "contextWindow" => model["context_window"]
              }
            ]
          end

        _ ->
          []
      end)

    case visible do
      [] -> {:error, "No Codex models were returned. The existing model list was kept."}
      _ -> {:ok, Enum.uniq_by(visible, & &1["id"])}
    end
  end
end

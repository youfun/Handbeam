defmodule Handbeam.Agent.Provider.StepFun do
  @moduledoc """
  StepFun / Step Plan provider adapter.

  Step Plan (`step-router-v1`) uses the OpenAI Chat Completions API at
  `{baseUrl}/chat/completions`. This adapter supplies StepFun defaults
  (base URL, long receive timeout, API-key isolation) while delegating
  request/response mapping and SSE parsing to `OpenAICompat` /
  `OpenAIStream`.

  `reasoning_content` deltas are accumulated as thinking blocks and are
  not appended to visible assistant text.

  The `stepfun-anthropic` provider (`api: "anthropic-messages"`) is a
  separate path and continues to use `Handbeam.Agent.Provider.Anthropic`.
  """

  @behaviour Handbeam.Agent.Provider

  alias Handbeam.Agent.Provider.OpenAICompat

  @default_base_url "https://api.stepfun.com/step_plan/v1"
  @default_model "step-router-v1"
  @default_receive_timeout 600_000
  @default_connect_timeout 30_000

  @impl true
  def complete(messages, tool_defs, config) do
    config
    |> normalize_config()
    |> require_api_key()
    |> case do
      {:ok, normalized_config} ->
        OpenAICompat.complete(messages, tool_defs, normalized_config)

      {:error, :missing_api_key} ->
        {:error,
         "StepFun apiKey not configured. Set `apiKey` in ~/.handbeam/models.json or pass :api_key in config."}
    end
  end

  @impl true
  def stream(messages, tool_defs, config, on_chunk) do
    config
    |> Map.put(:stream, true)
    |> Map.put(:on_chunk, on_chunk)
    |> then(&complete(messages, tool_defs, &1))
  end

  defp normalize_config(config) do
    receive_timeout = Map.get(config, :receive_timeout, @default_receive_timeout)
    connect_timeout = Map.get(config, :connect_timeout, @default_connect_timeout)

    req_options =
      config
      |> Map.get(:req_options, [])
      |> Keyword.put_new(:receive_timeout, receive_timeout)
      |> Keyword.put_new(:connect_options, timeout: connect_timeout)

    config
    |> Map.put_new(:base_url, @default_base_url)
    |> Map.put_new(:model, @default_model)
    |> Map.put(:req_options, req_options)
  end

  defp require_api_key(%{api_key: key} = config) when is_binary(key) and key != "",
    do: {:ok, config}

  defp require_api_key(_config), do: {:error, :missing_api_key}
end

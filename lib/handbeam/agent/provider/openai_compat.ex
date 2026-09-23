defmodule Handbeam.Agent.Provider.OpenAICompat do
  @moduledoc """
  OpenAI-compatible Chat Completions provider (vendored from Alloy).

  Supports any service that implements the OpenAI `/v1/chat/completions` API,
  including OpenAI, OpenRouter, vLLM, LM Studio, Ollama, DeepSeek, StepFun, etc.

  ## Configuration

    - `:base_url` — API base URL, defaults to `"https://api.stepfun.com/step_plan/v1"`
    - `:api_key` — API key, falls back to `OPENAI_API_KEY` env var
    - `:model` — model name, defaults to `"step-router-v1"`
    - `:max_tokens` — max tokens in response
    - `:temperature` — sampling temperature
    - `:req_module` — injectable Req module for testing
    - `:max_retries` — max retry attempts (default 3)
    - `:retry_delay_base_ms` — initial retry delay (default 500ms, doubles each retry)
  """

  @behaviour Handbeam.Agent.Provider

  alias Handbeam.Agent.Message
  alias Handbeam.Agent.Provider.{OpenAIStream, Retry}

  require Logger

  @default_base_url "https://api.stepfun.com/step_plan/v1"

  @impl true
  def complete(messages, tool_defs, config) do
    with {:ok, api_key} <- resolve_api_key(config) do
      body = build_request_body(messages, tool_defs, config)
      url = build_url(config)
      headers = build_headers(api_key, config)

      stream? = Map.get(config, :stream, false)
      on_chunk = Map.get(config, :on_chunk)

      if stream? and is_function(on_chunk, 1) do
        # Test mocks that only implement post/2 fall back to sync.
        # Mocks that implement request/1 (and the real Req module) use
        # OpenAI Chat Completions SSE via OpenAIStream.
        req_mod = Map.get(config, :req_module, Req)

        if req_mod != Req and not function_exported?(req_mod, :request, 1) do
          body = Map.put(body, :stream, false)
          complete_sync(url, body, headers, config)
        else
          OpenAIStream.stream(url, headers, body, on_chunk, req_options(config))
        end
      else
        # Tool call streaming falls back to non-streaming for stability.
        # Remove stream flag from body when falling back.
        body = Map.put(body, :stream, false)
        complete_sync(url, body, headers, config)
      end
    else
      {:error, :missing_api_key} ->
        {:error,
         "OPENAI_API_KEY not configured. Set the environment variable or pass :api_key in config."}
    end
  end

  # ── Sync completion ──

  defp complete_sync(url, body, headers, config) do
    case request_with_retry(url, body, headers, config) do
      {:ok, %{body: resp_body}} ->
        parse_response(resp_body)

      {:error, {:retry_exhausted, last_status, body}} ->
        Logger.error(
          "[OpenAICompat] Retry exhausted (HTTP #{last_status}): #{api_error_message(body)}"
        )

        {:error, "OpenAI API error #{last_status} (after retries): #{api_error_message(body)}"}

      {:error, {:api_error, status, body}} ->
        Logger.error("[OpenAICompat] HTTP #{status}: #{api_error_message(body)}")

        {:error, "OpenAI API error #{status}: #{api_error_message(body)}"}

      {:error, {:http_error, reason}} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  # ── Config building ──

  defp resolve_api_key(config) do
    key = Map.get(config, :api_key) || System.get_env("OPENAI_API_KEY")

    if is_binary(key) and byte_size(key) > 0 do
      {:ok, key}
    else
      {:error, :missing_api_key}
    end
  end

  defp build_url(config) do
    base = Map.get(config, :base_url, @default_base_url)
    String.trim_trailing(base, "/") <> "/chat/completions"
  end

  defp build_headers(api_key, config) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ] ++ extra_headers(config)
  end

  defp extra_headers(config) do
    case Map.get(config, :extra_headers, []) do
      headers when is_list(headers) -> headers
      _ -> []
    end
  end

  defp req_options(config) do
    caller_opts = Map.get(config, :req_options, [])
    req_mod = Map.get(config, :req_module, Req)

    if req_mod == Req do
      caller_opts
    else
      Keyword.put(caller_opts, :req_module, req_mod)
    end
  end

  # ── Request body ──

  defp build_request_body(messages, tool_defs, config) do
    stream_flag = Map.get(config, :stream, false)

    body = %{
      model: config[:model] || "step-router-v1",
      messages: build_openai_messages(messages, config),
      stream: stream_flag
    }

    body =
      if max_tokens = config[:max_tokens], do: Map.put(body, :max_tokens, max_tokens), else: body

    body =
      if temp = config[:temperature], do: Map.put(body, :temperature, temp), else: body

    body =
      if thinking = config[:thinking], do: Map.put(body, :thinking, thinking), else: body

    body =
      if reasoning_effort = config[:reasoning_effort],
        do: Map.put(body, :reasoning_effort, reasoning_effort),
        else: body

    body =
      if provider_options = config[:provider_options],
        do: Map.put(body, :provider_options, provider_options),
        else: body

    body =
      if provider_routing = config[:provider_routing],
        do: Map.put(body, :provider, provider_routing),
        else: body

    if tool_defs != [] do
      body
      |> Map.put(:tools, Enum.map(tool_defs, &to_openai_tool/1))
      |> Map.put(:tool_choice, "auto")
    else
      body
    end
  end

  # ── Message mapping ──

  defp build_openai_messages(messages, config) do
    system_msgs =
      if sp = config[:system_prompt], do: [%{role: "system", content: sp}], else: []

    system_msgs ++ Enum.flat_map(messages, &to_openai_messages/1)
  end

  defp to_openai_messages(%Message{role: :assistant, content: content}) when is_list(content) do
    # Separate tool_use blocks from text/thinking content
    {tool_blocks, text_blocks} =
      Enum.split_with(content, &(&1[:type] == "tool_use"))

    tool_calls =
      Enum.map(tool_blocks, fn tc ->
        %{
          id: tc[:id],
          type: "function",
          function: %{
            name: tc[:name],
            arguments: Handbeam.JSON.encode!(tc[:input] || %{})
          }
        }
      end)

    text_content =
      text_blocks
      |> Enum.filter(&(&1[:type] == "text"))
      |> Enum.map_join("\n", & &1[:text])

    [%{role: "assistant", content: text_content, tool_calls: tool_calls}]
  end

  defp to_openai_messages(%Message{role: :assistant, content: content})
       when is_binary(content) do
    [%{role: "assistant", content: content}]
  end

  defp to_openai_messages(%Message{role: :user, content: content}) when is_list(content) do
    parts =
      Enum.map(content, fn
        %{type: "text", text: text} ->
          %{type: "text", text: text}

        %{"type" => "text", "text" => text} ->
          %{type: "text", text: text}

        %{type: "image", mime_type: mime_type, data: data} ->
          %{type: "image_url", image_url: %{url: "data:#{mime_type};base64,#{data}"}}

        %{"type" => "image", "mime_type" => mime_type, "data" => data} ->
          %{type: "image_url", image_url: %{url: "data:#{mime_type};base64,#{data}"}}

        block ->
          block
      end)

    [%{role: "user", content: parts}]
  end

  defp to_openai_messages(%Message{role: :user, content: content}) do
    [%{role: "user", content: content}]
  end

  defp to_openai_messages(%Message{role: :tool_result, content: content}) when is_list(content) do
    Enum.map(content, fn block ->
      %{role: "tool", tool_call_id: block[:tool_use_id], content: block[:content]}
    end)
  end

  defp to_openai_messages(%Message{role: :tool_result, content: content}) when is_map(content) do
    [%{role: "tool", tool_call_id: content[:tool_use_id], content: content[:content]}]
  end

  # ── Tool definition mapping ──

  defp to_openai_tool(tool_def) do
    %{
      type: "function",
      function: %{
        name: tool_def.name,
        description: tool_def.description,
        parameters: tool_def.input_schema
      }
    }
  end

  # ── Response parsing ──

  defp parse_response(body) when is_binary(body) do
    case Handbeam.Agent.Provider.decode_body(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, _reason} -> {:error, "Failed to decode OpenAI-compatible response JSON"}
    end
  end

  defp parse_response(%{"error" => error}) do
    {:error, get_error_message(error)}
  end

  defp parse_response(%{"choices" => [choice | _]} = body) when is_map(choice) do
    [choice | _] = body["choices"]
    message = choice["message"]

    has_tool_calls = is_list(message["tool_calls"]) and message["tool_calls"] != []

    {stop_reason, messages} =
      if has_tool_calls do
        tool_calls = Enum.map(message["tool_calls"], &parse_tool_call/1)
        {:tool_use, [Message.tool_use(tool_calls)]}
      else
        text = message["content"] || ""
        {:end_turn, [Message.assistant(text)]}
      end

    usage_body = body["usage"] || %{}

    usage = Handbeam.Agent.Provider.openai_usage(usage_body)

    {:ok,
     %{
       stop_reason: stop_reason,
       messages: messages,
       usage: usage,
       provider_state: %{},
       response_metadata: %{id: body["id"], model: body["model"]}
     }}
  end

  defp parse_response(%{"choices" => []}) do
    {:error, "OpenAI-compatible response contained no choices"}
  end

  defp parse_response(body) do
    Logger.debug("[OpenAICompat] Unexpected response shape: #{inspect(body)}")
    {:error, "Unexpected OpenAI-compatible response shape"}
  end

  defp get_error_message(error) when is_map(error) do
    Map.get(error, "message") || Map.get(error, :message) || inspect(error)
  end

  defp get_error_message(error) when is_binary(error), do: error
  defp get_error_message(error), do: inspect(error)

  defp api_error_message(%{"error" => %{"message" => message}}) when is_binary(message),
    do: message

  defp api_error_message(%{error: %{message: message}}) when is_binary(message), do: message

  defp api_error_message(body) when is_binary(body) do
    cond do
      String.contains?(body, "<html") or String.contains?(body, "<!doctype html") ->
        body
        |> html_title()
        |> case do
          nil -> "provider returned HTML error page"
          title -> "provider returned HTML error page: #{title}"
        end

      String.trim(body) == "" ->
        "empty response body"

      true ->
        String.slice(String.trim(body), 0, 240)
    end
  end

  defp api_error_message(body), do: inspect(body)

  defp html_title(body) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, body) do
      [_, title] ->
        title
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.slice(0, 120)

      _ ->
        nil
    end
  end

  defp parse_tool_call(tc) do
    function = Map.get(tc, "function", %{})

    args =
      case Handbeam.JSON.decode(function["arguments"] || "{}") do
        {:ok, decoded} -> decoded
        {:error, _} -> %{}
      end

    name = function["name"]

    if (not is_binary(name) or String.trim(name) == "") and dev_env?() do
      Logger.debug("[OpenAICompat] parsed tool_call with missing name: #{inspect(tc)}")
    end

    %{
      type: "tool_use",
      id: tc["id"],
      name: name,
      input: args
    }
  end

  defp dev_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :dev
  end

  # ── Retry logic ──

  defp request_with_retry(url, body, headers, config) do
    req_mod = Map.get(config, :req_module, Req)

    do_retry = fn status, attempt ->
      case Retry.should_retry?(status, attempt, config) do
        {:retry, delay} ->
          Logger.warning(fn ->
            "[OpenAICompat] HTTP #{status}, retrying (attempt #{attempt + 1}, delay #{delay}ms)"
          end)

          Process.sleep(delay)
          :retry

        :exhausted ->
          :stop
      end
    end

    attempt_request(req_mod, url, body, headers, 0, do_retry, config)
  end

  defp attempt_request(req_mod, url, body, headers, attempt, do_retry, config) do
    # Default: 120s receive_timeout, 30s connect. Caller can override via config[:req_options].
    default_req_opts = [
      receive_timeout: 120_000,
      connect_options: [timeout: 30_000]
    ]

    caller_opts = Map.get(config, :req_options, [])

    req_opts =
      [json: body, headers: headers]
      |> Keyword.merge(default_req_opts)
      |> Keyword.merge(caller_opts)

    result = req_mod.post(url, req_opts)

    case result do
      {:ok, %{status: 200} = resp} ->
        {:ok, resp}

      {:ok, %{status: status} = resp} ->
        case do_retry.(status, attempt) do
          :retry -> attempt_request(req_mod, url, body, headers, attempt + 1, do_retry, config)
          :stop -> {:error, {:retry_exhausted, status, Map.get(resp, :body, %{})}}
        end

      {:error, reason} when attempt > 0 ->
        case do_retry.(500, attempt) do
          :retry -> attempt_request(req_mod, url, body, headers, attempt + 1, do_retry, config)
          :stop -> {:error, {:http_error, reason}}
        end

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end
end

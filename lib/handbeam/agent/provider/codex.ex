defmodule Handbeam.Agent.Provider.Codex do
  @moduledoc """
  Stateless SSE Responses transport for a personal ChatGPT/Codex subscription.

  Handbeam owns tools, approvals and the turn loop. Every request sends history;
  encrypted reasoning is retained in opaque content blocks, not server sessions.
  This backend is distinct from the public, API-key-billed OpenAI Responses API.
  """

  @behaviour Handbeam.Agent.Provider

  alias Handbeam.Agent.Auth.{CodexCredential, CodexOAuth}
  alias Handbeam.Agent.Message
  alias Handbeam.Agent.Provider.{OpenAI, SSE}

  @endpoint "https://chatgpt.com/backend-api/codex/responses"

  @impl true
  def complete(messages, tool_defs, config),
    do: stream(messages, tool_defs, config, fn _ -> :ok end)

  @impl true
  def stream(messages, tool_defs, config, on_chunk) do
    with {:ok, auth} <- resolve_auth(config) do
      initial = %{buffer: "", output: %{}, response: nil, error: nil}
      body = request_body(messages, tool_defs, config, auth)
      req = Map.get(config, :req_module, Req)

      options =
        Map.get(config, :req_options, [])
        |> Keyword.merge(
          url: @endpoint,
          method: :post,
          headers: headers(auth),
          body: Handbeam.JSON.encode!(body),
          into: stream_handler(initial, on_chunk),
          retry: false,
          redirect: false,
          receive_timeout: Map.get(config, :receive_timeout, 180_000),
          connect_options: [timeout: Map.get(config, :connect_timeout, 30_000)]
        )

      case req.request(options) do
        {:ok, %{status: 200} = response} ->
          finish(Map.get(response.private, :codex_sse, initial), auth, config)

        {:ok, %{status: 401}} ->
          {:error, "ChatGPT authorization rejected. Sign in again."}

        {:ok, %{status: 403}} ->
          {:error, "ChatGPT account does not have access to this Codex model."}

        {:ok, %{status: 429}} ->
          {:error,
           "ChatGPT Codex usage limit reached. Check your subscription usage and retry later."}

        {:ok, %{status: status}} ->
          {:error, "Codex request failed (HTTP #{status})."}

        {:error, _} ->
          {:error,
           "Codex connection ended without a complete response. Request was not replayed."}
      end
    end
  end

  @doc false
  def headers(auth) do
    [
      {"authorization", "Bearer #{auth.api_key}"},
      {"chatgpt-account-id", auth.account_id},
      {"originator", "handbeam"},
      {"user-agent", "handbeam/0.1.0"},
      {"openai-beta", "responses=experimental"},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]
  end

  defp resolve_auth(%{auth_type: :oauth} = config) do
    with {:ok, auth} <-
           CodexCredential.resolve_transport_key(config[:provider_key] || "openai_codex") do
      if config[:auth_generation] && config.auth_generation != auth.auth_generation do
        {:error, "ChatGPT account changed during this run. Start a new run."}
      else
        {:ok, auth}
      end
    end
  end

  defp resolve_auth(config) do
    with {:ok, account_id} <- CodexOAuth.account_id(config[:api_key]) do
      {:ok, %{api_key: config.api_key, account_id: account_id}}
    end
  end

  defp request_body(messages, tool_defs, config, auth) do
    body = %{
      "model" => config.model,
      "instructions" => config[:system_prompt] || "You are a helpful coding assistant.",
      "input" => Enum.flat_map(messages, &input_items(&1, auth.account_id, config.model)),
      "tools" => Enum.map(tool_defs, &OpenAI.format_tool_def/1),
      "store" => false,
      "stream" => true,
      "include" => ["reasoning.encrypted_content"],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true
    }

    case config[:reasoning] do
      reasoning when is_map(reasoning) ->
        Map.put(body, "reasoning", Handbeam.Agent.Provider.stringify_keys(reasoning))

      _ ->
        body
    end
  end

  defp input_items(%Message{role: :assistant, content: blocks} = message, account_id, model)
       when is_list(blocks) do
    Enum.flat_map(blocks, fn
      %{type: "codex_reasoning", account_id: ^account_id, model: ^model, item: item} -> [item]
      %{type: "codex_reasoning"} -> []
      block -> OpenAI.build_input_items([%{message | content: [block]}], %{})
    end)
  end

  defp input_items(message, _account_id, _model), do: OpenAI.build_input_items([message], %{})

  defp stream_handler(initial, on_chunk) do
    fn {:data, chunk}, {req, response} ->
      if response.status == 200 do
        acc = Map.get(response.private, :codex_sse, initial)
        {events, buffer} = SSE.process_chunk(acc.buffer, chunk)
        acc = Enum.reduce(events, %{acc | buffer: buffer}, &handle_event(&1, &2, on_chunk))
        {:cont, {req, put_in(response.private[:codex_sse], acc)}}
      else
        # Do not retain response bodies that could echo authorization data.
        {:cont, {req, response}}
      end
    end
  end

  defp handle_event(_event, %{error: error} = acc, _on_chunk) when not is_nil(error), do: acc
  defp handle_event(%{data: "[DONE]"}, acc, _on_chunk), do: acc

  defp handle_event(%{data: data}, acc, on_chunk) do
    case Handbeam.JSON.decode(data) do
      {:ok, %{"type" => type} = event} -> process_event(type, event, acc, on_chunk)
      _ -> %{acc | error: "Invalid Codex stream event"}
    end
  end

  defp process_event("response.output_text.delta", %{"delta" => text}, acc, on_chunk)
       when is_binary(text) do
    on_chunk.(text)
    acc
  end

  defp process_event(
         "response.output_item.done",
         %{"output_index" => index, "item" => item},
         acc,
         _
       )
       when is_integer(index) and is_map(item),
       do: %{acc | output: Map.put(acc.output, index, item)}

  defp process_event(type, %{"response" => response}, acc, _)
       when type in ["response.completed", "response.done"] and is_map(response),
       do: %{acc | response: response}

  defp process_event(type, _event, acc, _) when type in ["response.failed", "error"],
    do: %{acc | error: "Codex reported a failed response. No tools were executed."}

  defp process_event("response.incomplete", _event, acc, _),
    do: %{acc | error: "Codex response was incomplete. No tools were executed."}

  defp process_event(_type, _event, acc, _), do: acc

  defp finish(%{error: error}, _auth, _config) when not is_nil(error), do: {:error, error}

  defp finish(%{response: nil}, _auth, _config),
    do: {:error, "Codex stream ended before its terminal response. No tools were executed."}

  defp finish(%{response: response, output: streamed}, auth, config) do
    output =
      response["output"] || streamed |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

    with :ok <- validate_output(response, output),
         {:ok, parsed} <- OpenAI.parse_response(Map.put(response, "output", output)),
         {:ok, blocks} <- output_blocks(output, auth.account_id, config.model) do
      usage = response["usage"] || %{}

      {:ok,
       %{
         parsed
         | messages: [Message.assistant_blocks(blocks)],
           provider_state: %{},
           usage:
             Map.put(
               parsed.usage,
               :reasoning_tokens,
               get_in(usage, ["output_tokens_details", "reasoning_tokens"]) || 0
             )
       }}
    end
  end

  defp validate_output(%{"status" => status}, _)
       when status in ["failed", "incomplete", "cancelled"],
       do: {:error, "Codex response did not complete. No tools were executed."}

  defp validate_output(_, output) when is_list(output) do
    if Enum.all?(output, &valid_item?/1),
      do: :ok,
      else: {:error, "Invalid Codex output item. No tools were executed."}
  end

  defp validate_output(_, _), do: {:error, "Invalid Codex response output"}

  defp valid_item?(%{
         "type" => "function_call",
         "call_id" => id,
         "name" => name,
         "arguments" => args
       })
       when is_binary(id) and id != "" and is_binary(name) and name != "" and is_binary(args) do
    case Handbeam.JSON.decode(args) do
      {:ok, input} when is_map(input) -> true
      _ -> false
    end
  end

  defp valid_item?(%{"type" => "function_call"}), do: false
  defp valid_item?(%{"type" => type}) when type in ["message", "reasoning"], do: true
  defp valid_item?(_), do: false

  defp output_blocks(output, account_id, model) do
    result =
      Enum.reduce_while(output, {:ok, []}, fn
        %{"type" => "reasoning", "encrypted_content" => encrypted} = item, {:ok, acc}
        when is_binary(encrypted) ->
          block = %{
            type: "codex_reasoning",
            account_id: account_id,
            model: model,
            item: Map.take(item, ["type", "id", "summary", "encrypted_content"])
          }

          {:cont, {:ok, [[block] | acc]}}

        item, {:ok, acc} ->
          case OpenAI.parse_response(%{"output" => [item]}) do
            {:ok, %{messages: [message]}} -> {:cont, {:ok, [message.content | acc]}}
            error -> {:halt, error}
          end
      end)

    case result do
      {:ok, blocks} -> {:ok, blocks |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end
end

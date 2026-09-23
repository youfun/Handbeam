defmodule Handbeam.Agent.Provider.OpenAIStream do
  @moduledoc """
  Shared OpenAI-format SSE stream parser.

  Used by all OpenAI-compatible providers (OpenAI, DeepSeek, Mistral,
  OpenRouter, xAI, Ollama). Each provider calls `stream/5` with its
  own URL and headers; this module handles SSE parsing and response
  normalization.

  ## OpenAI Streaming Format

      data: {"choices":[{"index":0,"delta":{"content":"chunk"}}]}
      data: {"choices":[{"index":0,"delta":{"tool_calls":[...]}}]}
      data: [DONE]

  Text deltas are emitted via `on_chunk`. Tool call argument deltas
  are accumulated silently. The final response has the same shape as
  `complete/3`.
  """

  require Logger

  alias Handbeam.Agent.Message
  alias Handbeam.Agent.Provider.SSE

  @doc """
  Execute a streaming request against an OpenAI-compatible endpoint.

  Returns `{:ok, completion_response()} | {:error, term()}`.
  """
  @spec stream(String.t(), [{String.t(), String.t()}], map(), (String.t() -> :ok), keyword()) ::
          {:ok, Handbeam.Agent.Provider.completion_response()} | {:error, term()}
  def stream(url, headers, body, on_chunk, req_options) when is_function(on_chunk, 1) do
    tool_defs = tool_defs_from_body(body)

    body =
      body
      |> Map.put("stream", true)
      |> Map.put("stream_options", %{"include_usage" => true})

    initial_acc = %{
      buffer: "",
      content: "",
      reasoning_content: "",
      tool_calls: %{},
      finish_reason: nil,
      usage: %{},
      on_chunk: on_chunk,
      tool_defs: tool_defs
    }

    stream_handler = SSE.req_stream_handler(initial_acc, &handle_event/2)

    {req_mod, req_options} = Keyword.pop(req_options, :req_module, Req)

    req_opts =
      ([
         url: url,
         method: :post,
         headers: headers,
         body: Handbeam.JSON.encode!(body),
         into: stream_handler
       ] ++ req_options)
      |> Keyword.put(:retry, false)

    case req_mod.request(req_opts) do
      {:ok, %{status: 200} = resp} ->
        acc = Map.get(resp.private, :sse_acc, initial_acc)
        build_response(acc)

      {:ok, %{status: status} = resp} ->
        error_body = streaming_error_body(resp, initial_acc)
        {:error, parse_error(status, error_body)}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp streaming_error_body(resp, initial_acc) do
    case resp.body do
      "" ->
        sse_acc = Map.get(resp.private, :sse_acc, initial_acc)
        sse_acc.buffer

      body ->
        body
    end
  end

  # ── SSE Event Handling ───────────────────────────────────────────────

  @doc false
  def handle_event(acc, %{data: "[DONE]"}), do: acc

  def handle_event(acc, %{data: data}) do
    case Handbeam.JSON.decode(data) do
      {:ok, parsed} -> process_event(acc, parsed)
      {:error, _} -> acc
    end
  end

  @doc false
  def process_event(acc, %{"choices" => [%{"delta" => delta} | _]} = event) when is_map(delta) do
    acc = %{acc | usage: event["usage"] || acc.usage}

    acc =
      case delta do
        %{"content" => text} when is_binary(text) and text != "" ->
          acc.on_chunk.(text)
          %{acc | content: acc.content <> text}

        _ ->
          acc
      end

    acc =
      case delta do
        %{"reasoning_content" => text} when is_binary(text) and text != "" ->
          %{acc | reasoning_content: acc.reasoning_content <> text}

        _ ->
          acc
      end

    acc = accumulate_tool_calls(acc, Map.get(delta, "tool_calls", []))

    case event do
      %{"choices" => [%{"finish_reason" => reason} | _]} when is_binary(reason) ->
        %{acc | finish_reason: reason}

      _ ->
        acc
    end
  end

  # Choices without a text delta can still carry the final usage totals.
  def process_event(acc, %{"choices" => [%{} | _]} = event),
    do: %{acc | usage: event["usage"] || acc.usage}

  def process_event(acc, %{"choices" => [], "usage" => usage}) when is_map(usage) do
    %{acc | usage: usage}
  end

  def process_event(acc, %{"usage" => usage}) when is_map(usage) do
    %{acc | usage: usage}
  end

  def process_event(acc, _event), do: acc

  # ── Tool Call Accumulation ───────────────────────────────────────────

  defp accumulate_tool_calls(acc, []), do: acc

  defp accumulate_tool_calls(acc, tool_call_deltas) do
    tool_calls =
      Enum.reduce(tool_call_deltas, acc.tool_calls, fn tc_delta, tool_calls ->
        index = tc_delta["index"]
        existing = Map.get(tool_calls, index, %{id: nil, name: nil, arguments_buffer: ""})

        existing =
          case tc_delta do
            %{"id" => id} -> %{existing | id: id}
            _ -> existing
          end

        existing =
          case get_in(tc_delta, ["function", "name"]) do
            nil -> existing
            name -> %{existing | name: name}
          end

        existing =
          case get_in(tc_delta, ["function", "arguments"]) do
            nil -> existing
            args -> %{existing | arguments_buffer: existing.arguments_buffer <> args}
          end

        Map.put(tool_calls, index, existing)
      end)

    %{acc | tool_calls: tool_calls}
  end

  # ── Response Building ────────────────────────────────────────────────

  @doc false
  def build_response(acc) do
    reasoning_blocks =
      if acc.reasoning_content != "",
        do: [%{type: "thinking", thinking: acc.reasoning_content}],
        else: []

    text_blocks = if acc.content != "", do: [%{type: "text", text: acc.content}], else: []

    tool_blocks_result =
      acc.tool_calls
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.reduce_while([], fn {index, tc}, blocks ->
        input_result =
          case tc.arguments_buffer do
            "" -> {:ok, %{}}
            args -> Handbeam.JSON.decode(args)
          end

        name = resolved_tool_name(tc, input_result, acc)

        case {input_result, name} do
          {{:ok, input}, name} when is_binary(name) and name != "" ->
            # Streaming tool_call deltas from some providers (StepFun)
            # omit the top-level id and function name. Generate an id when
            # missing. Recover a name only when the arguments match exactly
            # one tool definition from this request.
            id = present(tc.id) || "call_#{index}"
            block = %{type: "tool_use", id: id, name: name, input: input}
            {:cont, [block | blocks]}

          {{:ok, _input}, _} ->
            dev_log(
              "[OpenAIStream] dropping tool_call with missing name " <>
                "index=#{inspect(index)} id=#{inspect(tc.id)} args=#{inspect(tc.arguments_buffer)}"
            )

            {:cont, blocks}

          {{:error, reason}, _} ->
            {:halt, {:error, "Invalid tool call JSON for #{tc.name}: #{inspect(reason)}"}}

          {:error, reason} ->
            {:halt, {:error, "Invalid tool call JSON for #{tc.name}: #{inspect(reason)}"}}
        end
      end)

    case tool_blocks_result do
      {:error, reason} ->
        {:error, reason}

      tool_blocks ->
        content_blocks = reasoning_blocks ++ text_blocks ++ Enum.reverse(tool_blocks)
        stop_reason = parse_finish_reason(acc.finish_reason)
        message = %Message{role: :assistant, content: content_blocks}

        {:ok,
         %{
           stop_reason: stop_reason,
           messages: [message],
           usage: Handbeam.Agent.Provider.openai_usage(acc.usage)
         }}
    end
  end

  defp resolved_tool_name(tc, {:ok, input}, acc) when is_map(input) do
    case present(tc.name) do
      name when is_binary(name) -> name
      _ -> unique_tool_name(input, Map.get(acc, :tool_defs, []))
    end
  end

  defp resolved_tool_name(_tc, _input_result, _acc), do: nil

  defp unique_tool_name(input, tool_defs) when is_map(input) and is_list(tool_defs) do
    matches =
      Enum.filter(tool_defs, fn defn ->
        schema = function_schema(defn)
        required = required_keys(schema)
        properties = schema_map(schema, "properties")

        required != [] and
          Enum.all?(required, &Map.has_key?(input, &1)) and
          Enum.all?(Map.keys(input), &property?(properties, &1))
      end)

    case matches do
      [defn] -> function_name(defn)
      _ -> nil
    end
  end

  defp unique_tool_name(_input, _tool_defs), do: nil

  defp tool_defs_from_body(body) when is_map(body) do
    body
    |> Map.get("tools", Map.get(body, :tools, []))
    |> List.wrap()
  end

  defp tool_defs_from_body(_), do: []

  defp function_schema(%{"function" => function}) when is_map(function),
    do: schema_map(function, "parameters")

  defp function_schema(%{function: function}) when is_map(function),
    do: schema_map(function, "parameters")

  defp function_schema(_), do: %{}

  defp function_name(%{"function" => function}) when is_map(function),
    do: present(schema_get(function, "name"))

  defp function_name(%{function: function}) when is_map(function),
    do: present(schema_get(function, "name"))

  defp function_name(_), do: nil

  defp required_keys(schema) do
    schema
    |> schema_map("required")
    |> Enum.filter(&is_binary/1)
  end

  defp schema_map(map, key) when is_map(map) do
    case schema_get(map, key) do
      value when is_map(value) or is_list(value) -> value
      _ -> if key == "required", do: [], else: %{}
    end
  end

  defp schema_map(_, "required"), do: []
  defp schema_map(_, _), do: %{}

  defp property?(properties, key) when is_map(properties) and is_binary(key) do
    Map.has_key?(properties, key) or
      (existing_atom?(key) and Map.has_key?(properties, String.to_existing_atom(key)))
  end

  defp property?(_, _), do: false

  defp schema_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, schema_atom(key))
  end

  defp schema_atom("function"), do: :function
  defp schema_atom("parameters"), do: :parameters
  defp schema_atom("properties"), do: :properties
  defp schema_atom("required"), do: :required
  defp schema_atom("name"), do: :name

  defp existing_atom?(key) do
    _ = String.to_existing_atom(key)
    true
  rescue
    ArgumentError -> false
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  defp parse_finish_reason("stop"), do: :end_turn
  defp parse_finish_reason("tool_calls"), do: :tool_use
  defp parse_finish_reason("length"), do: :end_turn
  defp parse_finish_reason("content_filter"), do: :end_turn
  defp parse_finish_reason(_), do: :end_turn

  defp dev_log(message) do
    if dev_env?(), do: Logger.debug(message)
  end

  defp dev_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :dev
  end

  defp parse_error(status, body) when is_binary(body) do
    case Handbeam.JSON.decode(body) do
      {:ok, %{"error" => error}} -> "#{error["type"]}: #{error["message"]}"
      _ -> "HTTP #{status}: #{body}"
    end
  end

  defp parse_error(status, body) when is_map(body) do
    case body do
      %{"error" => error} -> "#{error["type"]}: #{error["message"]}"
      _ -> "HTTP #{status}: #{inspect(body)}"
    end
  end
end

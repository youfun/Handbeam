defmodule Handbeam.MCP.HTTP do
  @moduledoc "Streamable HTTP MCP session: negotiated headers, JSON/SSE responses, no automatic retries."
  alias Handbeam.MCP.Protocol

  def initialize(cfg) do
    id = Protocol.generate_id()

    payload =
      request(id, "initialize", %{
        protocolVersion: Protocol.latest_version(),
        clientInfo: %{name: "Handbeam", version: to_string(Application.spec(:handbeam, :vsn))},
        capabilities: %{}
      })

    with {:ok, response} <- post(cfg, payload),
         {:ok, result} <- response(response.body, id),
         version when version in ["2024-11-05", "2025-03-26", "2025-06-18"] <-
           result["protocolVersion"] do
      session = List.first(Req.Response.get_header(response, "mcp-session-id"))
      headers = Map.put(cfg.runtime_headers, "mcp-protocol-version", version)
      headers = if session, do: Map.put(headers, "mcp-session-id", session), else: headers
      cfg = %{cfg | runtime_headers: headers}

      with {:ok, _} <- post(cfg, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}),
           {:ok, tools} <- list_tools(cfg, nil, [], MapSet.new()) do
        {:ok, cfg, tools}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "Server returned an unsupported MCP protocol version"}
    end
  end

  def call(cfg, method, params) do
    id = Protocol.generate_id()

    with {:ok, response} <- post(cfg, request(id, method, params)),
         do: response(response.body, id)
  end

  defp list_tools(cfg, cursor, acc, seen) do
    params = if cursor, do: %{cursor: cursor}, else: %{}

    with {:ok, %{"tools" => tools} = result} when is_list(tools) <-
           call(cfg, "tools/list", params) do
      next = result["nextCursor"]

      cond do
        is_nil(next) ->
          {:ok, acc ++ tools}

        not is_binary(next) or MapSet.member?(seen, next) or MapSet.size(seen) >= 100 ->
          {:error, "Invalid tools/list pagination"}

        true ->
          list_tools(cfg, next, acc ++ tools, MapSet.put(seen, next))
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "Invalid tools/list response"}
    end
  end

  defp request(id, method, params),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  defp post(cfg, payload) do
    headers =
      cfg.runtime_headers
      |> Map.new(fn {k, v} -> {String.downcase(k), v} end)
      |> Map.merge(%{
        "content-type" => "application/json",
        "accept" => "application/json, text/event-stream"
      })

    case Req.post(cfg.url,
           body: Handbeam.JSON.encode!(payload),
           headers: headers,
           decode_body: false,
           redirect: false,
           retry: false,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %{status: status}} -> {:error, "MCP HTTP #{status}"}
      {:error, _} -> {:error, "MCP HTTP request failed"}
    end
  end

  defp response(body, id) do
    case Handbeam.JSON.decode(body) do
      {:ok, %{"id" => ^id} = message} -> rpc_result(message)
      {:ok, _} -> {:error, "MCP response ID mismatch"}
      {:error, _} -> sse_response(body, id)
    end
  end

  defp sse_response(body, id) do
    body
    |> String.replace("\r\n", "\n")
    |> String.split("\n\n")
    |> Enum.find_value({:error, "No matching MCP response in event stream"}, fn event ->
      data =
        event
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map_join("\n", &(String.replace_prefix(&1, "data:", "") |> String.trim_leading()))

      case Handbeam.JSON.decode(data) do
        {:ok, %{"id" => ^id} = message} -> rpc_result(message)
        _ -> nil
      end
    end)
  end

  defp rpc_result(%{"error" => _}), do: {:error, "MCP server returned a JSON-RPC error"}
  defp rpc_result(message), do: Protocol.parse_response(message)
end

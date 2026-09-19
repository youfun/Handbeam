defmodule Handbeam.MCP.ServerRuntime do
  @moduledoc """
  Minimal MCP client runtime supporting both stdio and HTTP transports.

  * **stdio**: spawns an external command, communicates via newline-delimited JSON-RPC.
  * **HTTP**: connects to a streamable HTTP MCP endpoint via Req, communicates
    via JSON-RPC POST + SSE response.
  """

  use GenServer

  alias Handbeam.MCP.{Protocol, ServerConfig}

  require Logger

  @type tool_spec :: %{
          name: String.t(),
          description: String.t() | nil,
          input_schema: map()
        }

  @type http_state :: %{
          cfg: ServerConfig.t(),
          next_id: non_neg_integer(),
          tools: [tool_spec()],
          sse_buf: binary()
        }

  @type state ::
          {:stdio,
           %{
             cfg: ServerConfig.t(),
             port: port(),
             next_id: non_neg_integer(),
             tools: [tool_spec()],
             pending: %{binary() => {:from, {pid(), reference()}}}
           }}
          | {:http, http_state()}
  @type mcp_sse_state :: %{
          cfg: ServerConfig.t(),
          client: Req.t(),
          next_id: non_neg_integer(),
          tools: [tool_spec()],
          sse_buf: binary(),
          pending_sse: %{non_neg_integer() => {:from, {pid(), reference()}}}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec tools(pid()) :: {:ok, [tool_spec()]} | {:error, term()}
  def tools(pid), do: GenServer.call(pid, :tools, 10_000)

  @spec call_tool(pid(), String.t(), map()) ::
          {:ok, String.t(), map()} | {:ok, String.t()} | {:error, String.t()}
  def call_tool(pid, tool_name, input),
    do: GenServer.call(pid, {:call_tool, tool_name, input}, 60_000)

  @spec shutdown(pid()) :: :ok
  def shutdown(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Init — dispatch by transport kind
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    cfg = Keyword.fetch!(opts, :server_config)

    case transport_kind(cfg) do
      :stdio -> init_stdio(cfg)
      :http -> init_http(cfg)
    end
  end

  defp transport_kind(%ServerConfig{url: url}) when is_binary(url) and url != "", do: :http
  defp transport_kind(_), do: :stdio

  # -- stdio init --

  defp init_stdio(cfg) do
    with {:ok, port} <- open_port(cfg),
         {:ok, tools} <- do_stdio_initialize(cfg, port) do
      {:ok, {:stdio, %{cfg: cfg, port: port, next_id: 1, tools: tools, pending: %{}}}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp do_stdio_initialize(cfg, port) do
    state = %{cfg: cfg, port: port}

    with {:ok, _} <-
           stdio_rpc(state, "initialize", %{
             protocolVersion: Protocol.latest_version(),
             clientInfo: %{"name" => "Handbeam", "version" => app_version()},
             capabilities: %{}
           }),
         :ok <- stdio_notify(state, "initialized", %{}),
         {:ok, tools} <- stdio_list_tools(state) do
      {:ok, tools}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp stdio_list_tools(state) do
    case stdio_rpc(state, "tools/list", %{}) do
      {:ok, %{"tools" => tools}} when is_list(tools) ->
        {:ok,
         Enum.flat_map(tools, fn
           %{"name" => name} = tool ->
             [
               %{
                 name: name,
                 description: Map.get(tool, "description"),
                 input_schema: Map.get(tool, "inputSchema", %{})
               }
             ]

           %{"name" => name, "input_schema" => schema} = tool ->
             [%{name: name, description: Map.get(tool, "description"), input_schema: schema}]

           _ ->
             []
         end)}

      {:ok, other} ->
        {:error, "unexpected tools/list response: #{inspect(other)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- HTTP init --

  defp init_http(cfg) do
    Logger.debug("[MCP][HTTP] init_http for #{cfg.name}: url=#{cfg.url}")

    with {:ok, tools} <- do_http_initialize(cfg) do
      Logger.debug("[MCP][HTTP] init_http success: #{length(tools)} tools")
      {:ok, {:http, %{cfg: cfg, next_id: 1, tools: tools, sse_buf: ""}}}
    else
      {:error, reason} ->
        Logger.debug("[MCP][HTTP] init_http failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  defp do_http_initialize(cfg) do
    Logger.debug("[MCP][HTTP] do_http_initialize #{cfg.name}")

    with {:ok, _} <-
           http_rpc(cfg, "initialize", %{
             protocolVersion: Protocol.latest_version(),
             clientInfo: %{"name" => "Handbeam", "version" => app_version()},
             capabilities: %{}
           }),
         :ok <- http_notify(cfg, "initialized", %{}),
         {:ok, tools} <- http_list_tools(cfg) do
      {:ok, tools}
    else
      {:error, reason} ->
        Logger.error("[MCP][HTTP] initialize failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp http_list_tools(cfg) do
    case http_rpc(cfg, "tools/list", %{}) do
      {:ok, %{"tools" => tools}} when is_list(tools) ->
        {:ok,
         Enum.flat_map(tools, fn
           %{"name" => name} = tool ->
             [
               %{
                 name: name,
                 description: Map.get(tool, "description"),
                 input_schema: Map.get(tool, "inputSchema", %{})
               }
             ]

           %{"name" => name, "input_schema" => schema} = tool ->
             [%{name: name, description: Map.get(tool, "description"), input_schema: schema}]

           _ ->
             []
         end)}

      {:ok, other} ->
        {:error, "unexpected tools/list response: #{inspect(other)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Call handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call(:tools, _from, {:stdio, state}),
    do: {:reply, {:ok, state.tools}, {:stdio, state}}

  def handle_call(:tools, _from, {:http, state}), do: {:reply, {:ok, state.tools}, {:http, state}}

  def handle_call({:call_tool, tool_name, input}, _from, {:stdio, state}) do
    case stdio_rpc(state, "tools/call", %{name: tool_name, arguments: input || %{}}) do
      {:ok, result} -> {:reply, normalize_tool_result(result), {:stdio, state}}
      {:error, reason} -> {:reply, {:error, format_error(reason)}, {:stdio, state}}
    end
  end

  def handle_call({:call_tool, tool_name, input}, _from, {:http, state}) do
    case http_rpc(state.cfg, "tools/call", %{name: tool_name, arguments: input || %{}}) do
      {:ok, result} -> {:reply, normalize_tool_result(result), {:http, state}}
      {:error, reason} -> {:reply, {:error, format_error(reason)}, {:http, state}}
    end
  end

  @impl true
  def terminate(_reason, {:stdio, %{port: port}}), do: safe_close_port(port)
  def terminate(_reason, {:http, _state}), do: :ok

  # ---------------------------------------------------------------------------
  # stdio transport
  # ---------------------------------------------------------------------------

  defp open_port(%ServerConfig{command: command, args: args, env: env, cwd: cwd}) do
    executable = System.find_executable(command)

    if is_nil(executable) do
      {:error, "MCP command not found: #{command}"}
    else
      port_opts = [:binary, :exit_status, :use_stdio, :stderr_to_stdout, :hide]
      port_opts = if cwd, do: [{:cd, String.to_charlist(cwd)} | port_opts], else: port_opts

      port_opts =
        if map_size(env) > 0 do
          [
            {:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}
            | port_opts
          ]
        else
          port_opts
        end

      command_args = Enum.map(args || [], &to_string/1)

      {:ok,
       Port.open({:spawn_executable, executable}, [
         {:args, Enum.map(command_args, &String.to_charlist/1)} | port_opts
       ])}
    end
  end

  defp stdio_rpc(%{port: port} = state, method, params) do
    id = Protocol.generate_id()
    payload = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    send_port(port, payload)
    wait_for_stdio_response(port, id, state)
  end

  defp stdio_notify(%{port: port}, method, params) do
    send_port(port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
    :ok
  end

  defp send_port(port, payload) do
    bytes = Handbeam.JSON.encode!(payload) <> "\n"
    Port.command(port, bytes)
  end

  defp wait_for_stdio_response(port, id, state) do
    receive do
      {^port, {:data, data}} ->
        case parse_stdio_data(data) do
          {:ok, %{"id" => ^id} = msg} ->
            case Protocol.parse_response(msg) do
              {:ok, result} -> {:ok, result}
              {:error, err} -> {:error, err}
            end

          {:ok, %{"method" => _}} ->
            wait_for_stdio_response(port, id, state)

          {:ok, _other} ->
            wait_for_stdio_response(port, id, state)

          {:error, reason} ->
            {:error, reason}
        end

      {^port, {:exit_status, status}} ->
        {:error, "MCP server exited with status #{status}"}
    after
      15_000 ->
        {:error, "MCP request timed out"}
    end
  end

  defp parse_stdio_data(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, nil}, fn line, {:ok, _acc} ->
      case Handbeam.JSON.decode(line) do
        {:ok, msg} when is_map(msg) -> {:halt, {:ok, msg}}
        {:ok, _} -> {:halt, {:error, :invalid_message}}
        {:error, _err} -> {:cont, {:ok, nil}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # HTTP transport
  # ---------------------------------------------------------------------------

  defp http_rpc(cfg, method, params) do
    Logger.debug("[MCP][HTTP] #{method} to #{cfg.url}")
    id = Protocol.generate_id()
    payload = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    body = Handbeam.JSON.encode!(payload)

    Logger.debug(
      "[MCP][HTTP] Req.post #{cfg.url} headers=#{inspect(Map.keys(cfg.runtime_headers))}"
    )

    case Req.post(cfg.url,
           body: body,
           headers: Map.merge(cfg.runtime_headers, %{"Content-Type" => "application/json"}),
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse_http_response(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{truncate(body, 200)}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp http_notify(cfg, method, params) do
    payload = %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    body = Handbeam.JSON.encode!(payload)

    case Req.post(cfg.url,
           body: body,
           headers: Map.merge(cfg.runtime_headers, %{"Content-Type" => "application/json"}),
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{truncate(body, 200)}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  def parse_http_response(body) when is_binary(body) do
    case Handbeam.JSON.decode(body) do
      {:ok, %{"jsonrpc" => "2.0", "id" => _id, "result" => _result} = msg} ->
        Protocol.parse_response(msg)

      {:ok, %{"jsonrpc" => "2.0", "id" => _id, "error" => error}} ->
        {:error, error}

      {:ok, %{"result" => result}} ->
        {:ok, result}

      {:ok, other} ->
        {:error, "unexpected HTTP response: #{truncate(inspect(other), 200)}"}

      {:error, reason} ->
        {:error, "Invalid JSON response: #{inspect(reason)}"}
    end
  end

  # Req auto-decodes JSON, so body may already be a map
  def parse_http_response(%{"jsonrpc" => "2.0", "id" => _id, "result" => _result} = msg) do
    Protocol.parse_response(msg)
  end

  def parse_http_response(%{"jsonrpc" => "2.0", "id" => _id, "error" => error}),
    do: {:error, error}

  def parse_http_response(%{"result" => result}), do: {:ok, result}

  def parse_http_response(other),
    do: {:error, "unexpected response body type: #{truncate(inspect(other), 200)}"}

  defp truncate(string, max_len) do
    if String.length(string) > max_len do
      String.slice(string, 0, max_len) <> "..."
    else
      string
    end
  end

  # ---------------------------------------------------------------------------
  # Shared
  # ---------------------------------------------------------------------------

  defp normalize_tool_result(%{"content" => content} = result) when is_binary(content) do
    {:ok, content, Map.drop(result, ["content", "isError"])}
  end

  defp normalize_tool_result(%{"content" => content} = result) when is_list(content) do
    text =
      Enum.map_join(content, fn
        %{"type" => "text", "text" => text} -> text
        %{"text" => text} -> text
        other -> inspect(other)
      end)

    {:ok, text, Map.drop(result, ["content", "isError"])}
  end

  defp normalize_tool_result(%{"error" => error}), do: {:error, format_error(error)}
  defp normalize_tool_result(other), do: {:ok, inspect(other), %{raw: other}}

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp app_version do
    Application.spec(:handbeam, :vsn) |> to_string()
  rescue
    _ -> "unknown"
  end

  defp safe_close_port(port) do
    if is_port(port) and Port.info(port) != nil do
      Port.close(port)
    end
  rescue
    _ -> :ok
  end
end

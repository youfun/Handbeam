defmodule Handbeam.MCP.ToolBridge do
  @moduledoc """
  Bridges MCP server tools into Handbeam.Tool.Registry as virtual tools.
  """

  alias Handbeam.MCP.ServerConfig

  @spec register_server_tools(pid(), ServerConfig.t()) :: {:ok, [String.t()]} | {:error, term()}
  def register_server_tools(runtime_pid, server_config, opts \\ [])

  def register_server_tools(runtime_pid, %ServerConfig{name: server_name} = config, opts) do
    scope = Handbeam.MCP.Access.scope(opts)

    case Handbeam.MCP.ServerRuntime.tools(runtime_pid) do
      {:ok, tools} ->
        registered =
          Enum.map(tools, fn tool ->
            name = namespaced_name(server_name <> "_" <> String.slice(scope, 0, 12), tool.name)

            namespaced =
              if byte_size(name) > 64,
                do:
                  String.slice(name, 0, 43) <>
                    "_" <> String.slice(Handbeam.MCP.Access.fingerprint(name), 0, 20),
                else: name

            executor = fn input, context ->
              if Handbeam.MCP.Access.allowed?(config, opts, context) do
                timeout_ms = mcp_timeout(context)
                Handbeam.MCP.ServerRuntime.call_tool(runtime_pid, tool.name, input, timeout_ms)
              else
                {:error, "MCP server is disabled, changed, or not allowed in this workspace"}
              end
            end

            :ok =
              Handbeam.Tool.Registry.register_virtual(
                namespaced,
                tool.description,
                tool.input_schema,
                executor,
                deferred?: config.exposure != "direct",
                meta: %{
                  source: :mcp,
                  server: server_name,
                  remote_name: tool.name,
                  scope: scope,
                  exposure: config.exposure,
                  server_description: config.description,
                  fingerprint: Handbeam.MCP.Access.fingerprint(config),
                  runtime_pid: runtime_pid
                }
              )

            namespaced
          end)

        {:ok, registered}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def unregister_server_tools(_server_name, tool_names \\ nil) do
    case tool_names do
      nil ->
        :ok

      names when is_list(names) ->
        Enum.each(names, &Handbeam.Tool.Registry.unregister/1)
        :ok
    end
  end

  defp mcp_timeout(context) when is_map(context) do
    remaining =
      case context[:run_deadline] do
        deadline when is_integer(deadline) ->
          max(deadline - System.monotonic_time(:millisecond), 1)

        _ ->
          nil
      end

    tool_cap = context[:tool_timeout] || 60_000
    if is_integer(remaining), do: min(tool_cap, remaining), else: tool_cap
  end

  defp mcp_timeout(_context), do: 60_000

  def namespaced_name(server_name, tool_name) do
    "mcp__#{server_name}__#{tool_name}"
  end
end

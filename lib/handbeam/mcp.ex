defmodule Handbeam.MCP do
  @moduledoc "Owns independent MCP runtime sets for each workspace/configuration source."
  use GenServer
  alias Handbeam.MCP.{Access, ConfigLoader, RuntimeSupervisor, ServerRuntime, ToolBridge}

  def load_config(opts \\ []), do: ConfigLoader.load(opts)
  def start_runtime(opts \\ []), do: RuntimeSupervisor.start_runtime(opts)
  def bootstrap(opts \\ []), do: GenServer.call(__MODULE__, {:bootstrap, opts}, 120_000)
  def teardown_previous(opts \\ []), do: GenServer.call(__MODULE__, {:teardown, opts}, 120_000)
  def register_runtime_tools(pid, cfg), do: ToolBridge.register_server_tools(pid, cfg)
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:bootstrap, opts}, _from, scopes) do
    # Include full connection configuration, not just server names, in cache validation.
    opts = Keyword.put_new(opts, :user_config_path, Handbeam.MCP.Settings.path())
    key = Access.scope(opts)
    config = Access.config(opts)
    previous = Map.get(scopes, key)

    if previous && previous.config == config && previous.server_errors == [] &&
         Enum.all?(previous.runtime_pids, &Process.alive?/1) &&
         Enum.all?(previous.registered, &(Handbeam.Tool.Registry.get(&1) != :error)) do
      {:reply, {:ok, previous}, scopes}
    else
      if previous, do: retire(previous)
      result = start_servers(config, opts)
      {:reply, {:ok, result}, Map.put(scopes, key, result)}
    end
  end

  def handle_call({:teardown, _opts}, _from, scopes) do
    Enum.each(scopes, fn {_, result} -> retire(result) end)

    Handbeam.Tool.Registry.list()
    |> Enum.filter(&String.starts_with?(&1, "mcp__"))
    |> Enum.each(&Handbeam.Tool.Registry.unregister/1)

    {:reply, :ok, %{}}
  end

  defp start_servers(config, opts) do
    Enum.reduce(
      config.servers,
      %{config: config, registered: [], runtime_pids: [], server_errors: []},
      fn {name, cfg}, acc ->
        case start_runtime(server_config: cfg) do
          {:ok, pid} ->
            case ToolBridge.register_server_tools(pid, cfg, opts) do
              {:ok, tools} ->
                %{
                  acc
                  | registered: acc.registered ++ tools,
                    runtime_pids: [pid | acc.runtime_pids]
                }

              {:error, _} ->
                ServerRuntime.shutdown(pid)

                %{
                  acc
                  | server_errors: [
                      %{server: name, error: "Tool discovery failed"} | acc.server_errors
                    ]
                }
            end

          {:error, _} ->
            %{
              acc
              | server_errors: [%{server: name, error: "Connection failed"} | acc.server_errors]
            }
        end
      end
    )
  end

  defp retire(result) do
    Enum.each(result.registered, &Handbeam.Tool.Registry.unregister/1)
    # Stop behind any in-flight call, without blocking other workspaces or cancelling that call.
    Enum.each(result.runtime_pids, fn pid ->
      Task.Supervisor.start_child(Handbeam.AgentRunTaskSupervisor, fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 65_000)
      end)
    end)
  end
end

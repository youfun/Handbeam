defmodule Handbeam.MCP do
  @moduledoc """
  MCP integration entrypoint.
  """

  alias Handbeam.MCP.{ConfigLoader, RuntimeSupervisor, ToolBridge}

  require Logger
  use GenServer

  @spec load_config(keyword()) :: {:ok, Handbeam.MCP.Config.t()}
  def load_config(opts \\ []), do: ConfigLoader.load(opts)

  @spec start_runtime(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_runtime(opts \\ []) do
    RuntimeSupervisor.start_runtime(opts)
  end

  @spec bootstrap(keyword()) :: {:ok, map()} | {:error, term()}
  def bootstrap(opts \\ []) do
    GenServer.call(__MODULE__, {:bootstrap, opts}, 60_000)
  end

  @spec teardown_previous(keyword()) :: :ok
  def teardown_previous(opts \\ []) do
    GenServer.call(__MODULE__, {:teardown, opts}, 10_000)
  end

  @spec register_runtime_tools(pid(), Handbeam.MCP.ServerConfig.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def register_runtime_tools(runtime_pid, server_config),
    do: ToolBridge.register_server_tools(runtime_pid, server_config)

  # ──── GenServer ────

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{cache: %{}}}
  end

  @impl true
  def handle_call({:bootstrap, opts}, _from, state) do
    case ConfigLoader.load(opts) do
      {:ok, config} ->
        cache_key = config_cache_key_from_config(config)

        case Map.fetch(state.cache, cache_key) do
          {:ok, result} ->
            Logger.debug(
              "[MCP] bootstrap skipped — same config already loaded (#{length(result.registered)} tools)"
            )

            {:reply, {:ok, result}, state}

          :error ->
            # Only teardown if config differs from every cached entry
            needs_teardown =
              Enum.any?(state.cache, fn {_key, cached} ->
                not configs_match?(cached.config, config)
              end)

            new_state = if needs_teardown, do: do_teardown(state), else: state

            {runtimes, server_diags} =
              Enum.reduce(config.servers, {[], []}, fn {name, server}, {rt_acc, diag_acc} ->
                case start_runtime(server_config: server) do
                  {:ok, runtime_pid} ->
                    case register_runtime_tools(runtime_pid, server) do
                      {:ok, tool_names} ->
                        {[%{registered: tool_names, runtime_pid: runtime_pid} | rt_acc], diag_acc}

                      {:error, reason} ->
                        Logger.warning(
                          "[MCP] tool registration failed for \"#{name}\": #{inspect(reason)}"
                        )

                        {[%{runtime_pid: runtime_pid} | rt_acc], diag_acc}
                    end

                  {:error, reason} ->
                    Logger.warning("[MCP] failed to start server \"#{name}\": #{inspect(reason)}")
                    {rt_acc, [%{server: name, error: inspect(reason)} | diag_acc]}
                end
              end)

            runtimes =
              runtimes
              |> Enum.reverse()
              |> Enum.reduce(%{registered: [], runtime_pids: []}, fn
                %{registered: tools, runtime_pid: pid}, acc ->
                  %{
                    acc
                    | registered: acc.registered ++ tools,
                      runtime_pids: [pid | acc.runtime_pids]
                  }

                %{runtime_pid: pid}, acc ->
                  %{acc | runtime_pids: [pid | acc.runtime_pids]}
              end)

            result =
              Map.merge(%{config: config, server_errors: Enum.reverse(server_diags)}, runtimes)

            if server_diags != [] do
              Logger.warning(
                "[MCP] #{length(server_diags)} server(s) failed to start: #{inspect(server_diags)}"
              )
            end

            Logger.info(
              "[MCP] bootstrap complete: #{length(result.registered)} tools registered from #{map_size(config.servers)} servers"
            )

            new_state = %{new_state | cache: Map.put(new_state.cache, cache_key, result)}
            {:reply, {:ok, result}, new_state}
        end
    end
  end

  @impl true
  def handle_call({:teardown, _opts}, _from, state) do
    {:reply, :ok, do_teardown(state)}
  end

  # ──── internal ────

  defp do_teardown(state) do
    # Unregister all existing mcp__ tools
    old_tools = Enum.filter(Handbeam.Tool.Registry.list(), &String.starts_with?(&1, "mcp__"))
    Enum.each(old_tools, &Handbeam.Tool.Registry.unregister/1)

    # Shut down previous ServerRuntime processes
    old_pids = :ets.tab2list(runtime_pids_table()) |> Enum.map(&elem(&1, 0))

    Enum.each(old_pids, fn pid ->
      if Process.alive?(pid), do: Handbeam.MCP.ServerRuntime.shutdown(pid)
    end)

    # Clear cache and ETS tables
    :ets.delete_all_objects(runtime_pids_table())
    %{state | cache: %{}}
  end

  defp configs_match?(a, b) do
    a == b
  end

  defp config_cache_key_from_config(config) do
    names = Enum.map(Enum.sort_by(config.servers, fn {k, _} -> k end), fn {k, _} -> k end)
    {:servers, names}
  end

  # ETS set for tracking runtime PIDs
  defp runtime_pids_table do
    case :ets.whereis(:handbeam_mcp_runtimes) do
      :undefined -> :ets.new(:handbeam_mcp_runtimes, [:set, :public])
      existing -> existing
    end
  end
end

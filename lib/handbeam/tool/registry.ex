defmodule Handbeam.Tool.Registry do
  @moduledoc """
  Tool Registry — central registry for all available tools.

  Tools are registered with their unique name and module. The registry
  provides lookup, listing, and tool definition generation for providers.

  ## Design principle

  Even in MVP, all tools (builtin + memory) go through the registry.
  This prevents hardcoding tool modules into the Agent Core and makes
  V1 extension loading a non-breaking addition.
  """

  use GenServer

  require Logger

  # ── Client API ──

  @doc "Start the registry."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a tool module. Pass `override: true` to replace an existing name."
  @spec register(module()) :: :ok | {:error, term()}
  @spec register(module(), keyword()) :: :ok | {:error, term()}
  def register(tool_mod, opts \\ []) when is_atom(tool_mod) and is_list(opts) do
    GenServer.call(__MODULE__, {:register, tool_mod, opts})
  end

  @doc """
  Atomically replace every module-owned tool with `tool_mods`.

  An owner may replace its own entries, but it cannot overwrite a tool
  belonging to another owner (including an unowned builtin/programmatic
  entry). This is the primitive used by extension reload and in-memory
  mounts so stale tools cannot survive a successful replacement.
  """
  @spec replace_owner(term(), [module()]) :: :ok | {:error, term()}
  def replace_owner(owner, tool_mods) when is_list(tool_mods) do
    GenServer.call(__MODULE__, {:replace_owner, owner, tool_mods})
  end

  @doc "Remove all tools owned by `owner`."
  @spec remove_owner(term()) :: :ok
  def remove_owner(owner) do
    GenServer.call(__MODULE__, {:remove_owner, owner})
  end

  @doc "Register a virtual tool backed by an executor function."
  @spec register_virtual(String.t(), String.t() | nil, map(), (map(), map() -> any()), keyword()) ::
          :ok | {:error, term()}
  def register_virtual(name, description, input_schema, executor, opts \\ [])

  def register_virtual(name, description, input_schema, executor, opts)
      when is_binary(name) and is_function(executor, 2) do
    GenServer.call(
      __MODULE__,
      {:register_virtual, name, description, input_schema, executor, opts}
    )
  end

  @doc "Get a tool entry by name."
  @spec get(String.t()) :: {:ok, map()} | :error
  def get(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:get, name})
  end

  @doc "List all registered tool names."
  @spec list() :: [String.t()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Get all tool definitions for provider consumption."
  @spec tool_defs() :: [map()]
  def tool_defs do
    GenServer.call(__MODULE__, :tool_defs)
  end

  @doc "Get tool_name => tool entry map for executor lookups."
  @spec tool_fns() :: %{String.t() => map()}
  def tool_fns do
    GenServer.call(__MODULE__, :tool_fns)
  end

  @doc "Remove a tool by name."
  @spec unregister(String.t()) :: :ok
  def unregister(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:unregister, name})
  end

  @doc "Reset the registry, clearing all registered tools."
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc "Set the active tool list for a session (nil means all available)."
  @spec set_active_for_session(String.t(), [String.t()] | nil) :: :ok
  def set_active_for_session(session_id, tool_names) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:set_active_for_session, session_id, tool_names})
  end

  @doc "Get the active tool list for a session."
  @spec active_for_session(String.t()) :: [String.t()] | nil
  def active_for_session(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:active_for_session, session_id})
  end

  @doc "Get tool_defs filtered by session's active set. nil = all tools."
  @spec tool_defs_for_session(String.t()) :: [map()]
  def tool_defs_for_session(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:tool_defs_for_session, session_id})
  end

  # ── Server Callbacks ──

  @doc """
  Builtin modules seeded from the current `Handbeam.Host` capabilities.

  Single source of truth for host-gated tool seeding: registry `init/1`
  and `Handbeam.Agent.default_tools/0` both read this list. Android writes Host
  before starting `:handbeam`, so registry init must include `browser` and
  `preview_serve` when `webview_browser?` is true, and the Android intent
  tools plus `run_elixir_script` when `system_intents?` is true.
  """
  @spec host_tool_modules() :: [module()]
  def host_tool_modules do
    for %{module: mod, enabled: true} <- host_tool_configuration(), do: mod
  end

  @doc "Host seed decisions, not registration, dependency or run authorization facts."
  def host_tool_configuration do
    base = [
      Handbeam.Tool.Builtin.CodeSearch,
      Handbeam.Tool.Builtin.Edit,
      Handbeam.Tool.Builtin.FileSearch,
      Handbeam.Tool.Builtin.Git,
      Handbeam.Tool.Builtin.Grep,
      Handbeam.Tool.Builtin.JobStatus,
      Handbeam.Tool.Builtin.JobCancel,
      Handbeam.Tool.Builtin.MixProject,
      Handbeam.Tool.Builtin.Read,
      Handbeam.Tool.Builtin.Skill,
      Handbeam.Tool.Builtin.Advisor,
      Handbeam.Tool.Builtin.Task,
      Handbeam.Tool.Builtin.TaskStatus,
      Handbeam.Tool.Builtin.WebFetch,
      Handbeam.Tool.Builtin.Write,
      Handbeam.Tool.Builtin.FindThread,
      Handbeam.Tool.Builtin.ReadThread,
      Handbeam.Tool.Builtin.GetThreadStatus,
      Handbeam.Tool.Builtin.SendThreadMessage,
      Handbeam.Tool.Builtin.ReplyToParentThread,
      Handbeam.Tool.Builtin.CreateThread,
      Handbeam.Tool.Memory.MemAssociate,
      Handbeam.Tool.Memory.MemLearn,
      Handbeam.Tool.Memory.MemRecall,
      Handbeam.Tool.Memory.MemReinforce,
      Handbeam.Tool.Extension.MountApply,
      Handbeam.Tool.Extension.MountDrop
    ]

    base
    |> Enum.map(&%{module: &1, enabled: true, source: :unconditional_seed})
    |> host_gate(Handbeam.Host.shell?(), Handbeam.Tool.Builtin.Bash, :shell)
    |> host_gate(
      Handbeam.Host.desktop_browser?() or Handbeam.Host.webview_browser?(),
      Handbeam.Tool.Builtin.Browser,
      :desktop_or_webview_browser
    )
    |> host_gate(
      Handbeam.Host.webview_browser?(),
      Handbeam.Tool.Builtin.PreviewServe,
      :webview_browser
    )
    |> host_gate(
      Handbeam.Host.system_intents?(),
      Handbeam.Tool.Builtin.AndroidOpenUrl,
      :system_intents
    )
    |> host_gate(
      Handbeam.Host.system_intents?(),
      Handbeam.Tool.Builtin.AndroidOpenFile,
      :system_intents
    )
    |> host_gate(
      Handbeam.Host.system_intents?(),
      Handbeam.Tool.Builtin.AndroidShareFile,
      :system_intents
    )
    |> host_gate(
      Handbeam.Host.system_intents?(),
      Handbeam.Tool.Builtin.RunElixirScript,
      :system_intents
    )
    |> host_gate(Handbeam.Host.beam_eval?(), Handbeam.Tool.Extension.Beam.Docs, :beam_eval)
    |> host_gate(Handbeam.Host.beam_eval?(), Handbeam.Tool.Extension.Beam.Source, :beam_eval)
    |> host_gate(Handbeam.Host.beam_eval?(), Handbeam.Tool.Extension.Beam.Sql, :beam_eval)
  end

  defp host_gate(list, enabled, mod, source),
    do: list ++ [%{module: mod, enabled: enabled, source: source}]

  # ── BEAM introspection tools (registered on-demand for security) ──

  @beam_tools %{
    # P0 — safe read-only introspection
    docs: Handbeam.Tool.Extension.Beam.Docs,
    source: Handbeam.Tool.Extension.Beam.Source,
    sql: Handbeam.Tool.Extension.Beam.Sql,
    schemas: Handbeam.Tool.Extension.Beam.Schemas,
    sup_tree: Handbeam.Tool.Extension.Beam.SupTree,
    top: Handbeam.Tool.Extension.Beam.Top,
    # P1 — sensitive (reads process state)
    process_info: Handbeam.Tool.Extension.Beam.ProcessInfo,
    # P1 — powerful (executes code)
    eval: Handbeam.Tool.Extension.Beam.Eval,
    # Cross-session (reads/writes other sessions)
    sessions: Handbeam.Tool.Extension.Beam.Sessions,
    session_snapshot: Handbeam.Tool.Extension.Beam.SessionSnapshot,
    session_steer: Handbeam.Tool.Extension.Beam.SessionSteer
  }

  @doc """
  Register all BEAM introspection and cross-session tools.

  These are NOT registered by default for security — call this explicitly
  when you want to enable BEAM-level introspection and cross-session operations.

  Can be called with `:safe_only` to register only read-only tools
  (docs, source, sql, schemas, sup_tree, top, sessions, session_snapshot),
  excluding `eval`, `process_info`, and `session_steer`.
  """
  @spec register_beam_tools(atom()) :: :ok
  def register_beam_tools(level \\ :all) do
    allowed =
      case level do
        :safe_only ->
          Map.drop(@beam_tools, [:eval, :process_info, :session_steer])

        :all ->
          @beam_tools
      end

    Enum.each(allowed, fn {_key, mod} ->
      register(mod)
    end)

    :ok
  end

  @impl true
  def init(_opts) do
    tools =
      Enum.reduce(host_tool_modules(), %{}, fn mod, acc ->
        entry = build_module_entry(mod, nil)
        Map.put(acc, entry.name, entry)
      end)

    Logger.debug(
      "[ToolRegistry] Registered #{map_size(tools)} tools: #{inspect(Map.keys(tools))}"
    )

    {:ok, %{tools: tools, active_sets: %{}}}
  end

  @impl true
  def handle_call({:register, tool_mod, opts}, _from, state) do
    entry = build_module_entry(tool_mod, Keyword.get(opts, :owner))
    override? = Keyword.get(opts, :override, false)

    if Map.has_key?(state.tools, entry.name) and not override? do
      {:reply, :ok, state}
    else
      {:reply, :ok, %{state | tools: Map.put(state.tools, entry.name, entry)}}
    end
  end

  def handle_call({:replace_owner, owner, tool_mods}, _from, state) do
    try do
      entries =
        tool_mods
        |> Enum.uniq()
        |> Enum.map(&build_module_entry(&1, owner))

      incoming = Map.new(entries, &{&1.name, &1})

      conflicts =
        Enum.find_value(incoming, fn {name, _entry} ->
          case Map.get(state.tools, name) do
            nil ->
              nil

            existing ->
              if Map.get(existing.meta, :owner) != owner do
                {name, existing}
              else
                nil
              end
          end
        end)

      case conflicts do
        nil ->
          tools =
            state.tools
            |> remove_owned_tools(owner)
            |> Map.merge(incoming)

          {:reply, :ok, %{state | tools: tools}}

        {name, existing} ->
          {:reply, {:error, {:tool_name_collision, name, Map.get(existing.meta, :owner)}}, state}
      end
    rescue
      exception ->
        {:reply, {:error, {:invalid_tool, Exception.message(exception)}}, state}
    end
  end

  def handle_call({:remove_owner, owner}, _from, state) do
    {:reply, :ok, %{state | tools: remove_owned_tools(state.tools, owner)}}
  end

  def handle_call(
        {:register_virtual, name, description, input_schema, executor, opts},
        _from,
        state
      ) do
    entry = build_virtual_entry(name, description, input_schema, executor, opts)

    if Map.has_key?(state.tools, entry.name) do
      {:reply, :ok, state}
    else
      {:reply, :ok, %{state | tools: Map.put(state.tools, entry.name, entry)}}
    end
  end

  def handle_call({:get, name}, _from, state) do
    result =
      case Map.fetch(state.tools, name) do
        {:ok, entry} -> {:ok, entry}
        :error -> :error
      end

    {:reply, result, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.keys(state.tools), state}
  end

  def handle_call(:tool_defs, _from, state) do
    defs =
      Enum.map(
        state.tools,
        fn {_k, entry} ->
          %{name: entry.name, description: entry.description, input_schema: entry.input_schema}
        end
      )

    {:reply, defs, state}
  end

  def handle_call(:tool_fns, _from, state) do
    {:reply, state.tools, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    {:reply, :ok, %{state | tools: Map.delete(state.tools, name)}}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{tools: %{}, active_sets: %{}}}
  end

  def handle_call({:set_active_for_session, session_id, tool_names}, _from, state) do
    new_active_sets =
      case tool_names do
        nil -> Map.delete(state.active_sets, session_id)
        names -> Map.put(state.active_sets, session_id, names)
      end

    {:reply, :ok, %{state | active_sets: new_active_sets}}
  end

  def handle_call({:active_for_session, session_id}, _from, state) do
    {:reply, Map.get(state.active_sets, session_id), state}
  end

  def handle_call({:tool_defs_for_session, session_id}, _from, state) do
    defs =
      case Map.get(state.active_sets, session_id) do
        nil ->
          Enum.map(state.tools, fn {_k, entry} ->
            %{name: entry.name, description: entry.description, input_schema: entry.input_schema}
          end)

        active_names ->
          name_set = MapSet.new(active_names)

          state.tools
          |> Enum.filter(fn {name, _entry} -> MapSet.member?(name_set, name) end)
          |> Enum.map(fn {_name, entry} ->
            %{name: entry.name, description: entry.description, input_schema: entry.input_schema}
          end)
      end

    {:reply, defs, state}
  end

  defp build_module_entry(mod, owner) do
    %{
      kind: :module,
      name: mod.name(),
      description: mod.description(),
      input_schema: mod.input_schema(),
      module: mod,
      executor: &mod.execute/2,
      max_result_chars:
        if(function_exported?(mod, :max_result_chars, 0),
          do: mod.max_result_chars(),
          else: :unlimited
        ),
      concurrent?:
        if(function_exported?(mod, :concurrent?, 0), do: mod.concurrent?(), else: true),
      timeout_ms: if(function_exported?(mod, :timeout_ms, 0), do: mod.timeout_ms(), else: nil),
      meta: if(is_nil(owner), do: %{}, else: %{owner: owner})
    }
  end

  defp remove_owned_tools(tools, owner) do
    Map.reject(tools, fn {_name, entry} -> Map.get(entry.meta, :owner) == owner end)
  end

  defp build_virtual_entry(name, description, input_schema, executor, opts) do
    %{
      kind: :virtual,
      name: name,
      description: description,
      input_schema: input_schema || %{},
      module: nil,
      executor: executor,
      max_result_chars: Keyword.get(opts, :max_result_chars, :unlimited),
      concurrent?: Keyword.get(opts, :concurrent?, true),
      meta: Keyword.get(opts, :meta, %{})
    }
  end
end

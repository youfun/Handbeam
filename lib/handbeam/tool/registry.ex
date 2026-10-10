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

  @doc """
  Tool definitions declared to the provider.

  Nested-only and deferred tools stay registered. Nested-only tools are
  executable only through `Executor.execute_nested/4`. Deferred tools are
  omitted until a conversation loads them.
  """
  @spec tool_defs() :: [map()]
  def tool_defs do
    GenServer.call(__MODULE__, :tool_defs)
  end

  @doc "Get tool_name => tool entry map for executor lookups."
  @spec tool_fns() :: %{String.t() => map()}
  def tool_fns do
    GenServer.call(__MODULE__, :tool_fns)
  end

  @doc """
  Deferred tools with the fields needed for search and later declaration.

  Each map has `name`, `description`, `input_schema`, `server`, and
  `server_description`. These tools are absent from `tool_defs/0`.
  """
  @spec deferred_catalog() :: [map()]
  def deferred_catalog do
    GenServer.call(__MODULE__, :deferred_catalog)
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

  @doc """
  Session tool definitions declared to the provider.

  Nested-only and deferred tools are omitted even when the session active set
  names them. `nil` means every declared tool, not every registered tool.
  """
  @spec tool_defs_for_session(String.t()) :: [map()]
  def tool_defs_for_session(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:tool_defs_for_session, session_id})
  end

  @doc """
  Prompt text for tools the provider is allowed to see.

  Nested-only and deferred tools are omitted. An empty active set yields an empty string.
  """
  @spec prompt_snippets() :: String.t()
  def prompt_snippets do
    GenServer.call(__MODULE__, :prompt_snippets)
  end

  @doc "Session-scoped prompt snippets. Nested-only and deferred tools are omitted."
  @spec prompt_snippets_for_session(String.t()) :: String.t()
  def prompt_snippets_for_session(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:prompt_snippets_for_session, session_id})
  end

  # ── Server Callbacks ──

  @doc """
  Builtin modules seeded from the current `Handbeam.Host` declarations.

  Single source of truth for host-gated tool seeding: registry `init/1`
  and `Handbeam.Agent.default_tools/0` both read this list. The host writes
  backends before starting `:handbeam`. Registration follows the declared
  backend, not the OS, UI entry, or another capability.
  """
  @spec host_tool_modules() :: [module()]
  def host_tool_modules do
    for %{module: mod, enabled: true} <- host_tool_configuration(), do: mod
  end

  @doc "Host seed decisions, not registration, dependency or run authorization facts."
  def host_tool_configuration do
    alias Handbeam.Host

    base = [
      Handbeam.Tool.Builtin.CodeSearch,
      Handbeam.Tool.Builtin.Edit,
      Handbeam.Tool.Builtin.FileSearch,
      Handbeam.Tool.Builtin.Grep,
      Handbeam.Tool.Builtin.JobStatus,
      Handbeam.Tool.Builtin.JobCancel,
      Handbeam.Tool.Builtin.Read,
      Handbeam.Tool.Builtin.Skill,
      Handbeam.Tool.Builtin.Advisor,
      Handbeam.Tool.Builtin.Task,
      Handbeam.Tool.Builtin.TaskStatus,
      Handbeam.Tool.Builtin.ToolSearch,
      Handbeam.Tool.Builtin.ReadContext,
      Handbeam.Tool.Builtin.EditContext,
      Handbeam.Tool.Builtin.WebFetch,
      Handbeam.Tool.Builtin.Write,
      Handbeam.Tool.Builtin.FindThread,
      Handbeam.Tool.Builtin.ReadThread,
      Handbeam.Tool.Builtin.GetThreadStatus,
      Handbeam.Tool.Builtin.SendThreadMessage,
      Handbeam.Tool.Builtin.ReplyToParentThread,
      Handbeam.Tool.Builtin.CreateThread,
      Handbeam.Tool.Builtin.Schedule,
      Handbeam.Tool.Memory.MemAssociate,
      Handbeam.Tool.Memory.MemLearn,
      Handbeam.Tool.Memory.MemRecall,
      Handbeam.Tool.Memory.MemReinforce,
      Handbeam.Tool.Extension.MountApply,
      Handbeam.Tool.Extension.MountDrop
    ]

    base
    |> Enum.map(&%{module: &1, enabled: true, source: :agent_runtime})
    |> host_gate(
      Host.packaged_mix_toolchain?(),
      Handbeam.Tool.Builtin.MixProject,
      :packaged_mix_toolchain
    )
    |> host_gate(not is_nil(Host.get(:git_backend)), Handbeam.Tool.Builtin.Git, :git_backend)
    |> host_gate(
      not is_nil(Host.get(:computer_use_backend)),
      Handbeam.Tool.Builtin.Computer,
      :computer_use_backend
    )
    |> host_gate(Host.shell?(), Handbeam.Tool.Builtin.Bash, :shell)
    |> host_gate(
      not is_nil(Host.browser_backend()),
      Handbeam.Tool.Builtin.Browser,
      :browser_backend
    )
    |> host_gate(
      Host.browser_backend() == :webview,
      Handbeam.Tool.Builtin.PreviewServe,
      :browser_backend
    )
    |> host_gate(
      not is_nil(Host.artifact_delivery_backend()),
      Handbeam.Tool.Builtin.OpenUrl,
      :artifact_delivery_backend
    )
    |> host_gate(
      not is_nil(Host.artifact_delivery_backend()),
      Handbeam.Tool.Builtin.OpenFile,
      :artifact_delivery_backend
    )
    |> host_gate(
      not is_nil(Host.artifact_delivery_backend()),
      Handbeam.Tool.Builtin.ShareFile,
      :artifact_delivery_backend
    )
    |> host_gate(
      not is_nil(Host.artifact_delivery_backend()),
      Handbeam.Tool.Builtin.DeviceCalendar,
      :artifact_delivery_backend
    )
    |> host_gate(
      not is_nil(Host.artifact_delivery_backend()),
      Handbeam.Tool.Builtin.DeviceAlarm,
      :artifact_delivery_backend
    )
    |> host_gate(Host.host_script?(), Handbeam.Tool.Builtin.RunElixirScript, :host_script)
    |> host_gate(Host.beam_eval?(), Handbeam.Tool.Extension.Beam.Docs, :beam_eval)
    |> host_gate(Host.beam_eval?(), Handbeam.Tool.Extension.Beam.Source, :beam_eval)
    |> host_gate(Host.beam_eval?(), Handbeam.Tool.Extension.Beam.Sql, :beam_eval)
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
  rescue
    exception ->
      {:reply, {:error, {:invalid_tool, Exception.message(exception)}}, state}
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
    {:reply, declared_defs(state.tools, nil), state}
  end

  def handle_call(:tool_fns, _from, state) do
    {:reply, state.tools, state}
  end

  def handle_call(:deferred_catalog, _from, state) do
    catalog =
      state.tools
      |> Map.values()
      |> Enum.filter(&deferred_entry?/1)
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&catalog_entry/1)

    {:reply, catalog, state}
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
    {:reply, declared_defs(state.tools, Map.get(state.active_sets, session_id)), state}
  end

  def handle_call(:prompt_snippets, _from, state) do
    {:reply, format_prompt_snippets(state.tools, nil), state}
  end

  def handle_call({:prompt_snippets_for_session, session_id}, _from, state) do
    {:reply, format_prompt_snippets(state.tools, Map.get(state.active_sets, session_id)), state}
  end

  defp build_module_entry(mod, owner) do
    meta = if is_nil(owner), do: %{}, else: %{owner: owner}

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
      hint: tool_hint(mod),
      nested_only?: nested_only?(mod, meta),
      deferred?: deferred?(mod),
      meta: meta
    }
  end

  defp remove_owned_tools(tools, owner) do
    Map.reject(tools, fn {_name, entry} -> Map.get(entry.meta, :owner) == owner end)
  end

  defp build_virtual_entry(name, description, input_schema, executor, opts) do
    meta = Keyword.get(opts, :meta, %{})

    %{
      kind: :virtual,
      name: name,
      description: description,
      input_schema: input_schema || %{},
      module: nil,
      executor: executor,
      max_result_chars: Keyword.get(opts, :max_result_chars, :unlimited),
      concurrent?: Keyword.get(opts, :concurrent?, true),
      timeout_ms: Keyword.get(opts, :timeout_ms),
      hint: tool_hint(Keyword.get(opts, :hint)),
      nested_only?: nested_only?(nil, meta) or Keyword.get(opts, :nested_only?, false),
      deferred?: Keyword.get(opts, :deferred?, false) or deferred_exposure?(meta),
      meta: meta
    }
  end

  defp tool_hint(mod) when is_atom(mod) do
    if function_exported?(mod, :hint, 0), do: tool_hint(mod.hint()), else: nil
  end

  defp tool_hint(hint) when is_binary(hint) do
    case String.trim(hint) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp tool_hint(_hint), do: nil

  defp deferred?(mod) when is_atom(mod) do
    function_exported?(mod, :deferred?, 0) and mod.deferred?()
  end

  # Entries registered before `:deferred?` existed stay in the GenServer
  # across a code reload. Missing means eager, the only exposure those tools had.
  defp deferred_entry?(entry) when is_map(entry), do: Map.get(entry, :deferred?, false)

  defp deferred_exposure?(meta) do
    meta[:exposure] in ["deferred", "nested"] or meta["exposure"] in ["deferred", "nested"]
  end

  defp nested_only?(mod, meta) do
    module_flag =
      is_atom(mod) and function_exported?(mod, :nested_only?, 0) and mod.nested_only?()

    module_flag or truthy?(meta[:nested_only]) or truthy?(meta["nested_only"])
  end

  defp truthy?(value), do: value in [true, "true"]

  defp catalog_entry(entry) do
    %{
      name: entry.name,
      description: entry.description,
      input_schema: entry.input_schema,
      server: entry.meta[:server] || entry.meta["server"],
      server_description: entry.meta[:server_description] || entry.meta["server_description"]
    }
  end

  defp declared_defs(tools, active_names) do
    tools
    |> declared_entries(active_names)
    |> Enum.map(fn entry ->
      %{name: entry.name, description: entry.description, input_schema: entry.input_schema}
    end)
  end

  defp format_prompt_snippets(tools, active_names) do
    tools
    |> declared_entries(active_names)
    |> Enum.map_join("\n", fn entry ->
      "- #{entry.name}: #{entry.description}"
    end)
  end

  defp declared_entries(tools, active_names) do
    name_set = if is_list(active_names), do: MapSet.new(active_names)

    tools
    |> Map.values()
    |> Enum.filter(fn entry ->
      not entry.nested_only? and not deferred_entry?(entry) and
        (is_nil(name_set) or MapSet.member?(name_set, entry.name))
    end)
    |> Enum.sort_by(& &1.name)
  end
end

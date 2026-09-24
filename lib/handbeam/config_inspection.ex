defmodule Handbeam.ConfigInspection do
  @moduledoc """
  Read-only, deliberately allowlisted effective configuration report.

  Does not start the application, MCP, a browser or a run, resolve credentials,
  invoke host callbacks, or build tool descriptions/user prompts. Arbitrary
  strings (including paths, model IDs, rule patterns and extension names) are
  withheld, not regex-redacted. Host seeding is not model visibility.
  """

  alias Handbeam.{Host, Settings, WorkspaceSettings}
  alias Handbeam.Agent.{HostEnvironment, ModelConfig}
  alias Handbeam.Permissions.ToolPolicy
  alias Handbeam.Tool.Registry

  @capabilities ~w(shell terminal desktop_browser webview_browser system_intents beam_eval mcp dist packaged_mix_toolchain)a

  @doc "Inspect this VM. `workspace` selects settings, not another host or a running conversation."
  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    seeds = Registry.host_tool_configuration()
    registered = registered_names()
    workspace_settings = WorkspaceSettings.load(workspace)

    %{
      scope: :current_vm_not_a_run,
      host: capabilities(),
      tools: Enum.map(seeds, &tool(&1, registered)),
      registry: registry_summary(registered, seeds),
      model_visibility: %{status: :unknown, reason: :no_run_or_provider_request_inspected},
      execution: %{
        shell: shell_backend(),
        desktop_browser: dependency(Host.desktop_browser?(), "agent-browser"),
        webview: %{configured: Host.webview_browser?(), operational: :unknown},
        script: %{configured: Host.system_intents?(), backend: :host_beam_not_sandbox},
        mix_project: mix_project_backend(),
        git: git_backend(),
        code_index: code_index(workspace),
        mcp: %{configured: Host.mcp?(), operational: :unknown, reason: :not_probed}
      },
      ui: %{
        active_surface: :unknown,
        reason: :entry_surface_is_not_execution_host,
        web_server_configured: endpoint_server(),
        native_picker_configured: not is_nil(Host.get(:directory_picker)),
        native_intent_adapter_configured:
          not is_nil(Application.get_env(:handbeam, :android_intent)),
        source: :application_env,
        operational: :unknown
      },
      approval: approval(workspace_settings),
      model_ai: model_ai(workspace, opts),
      model_catalog: model_catalog(),
      sources: %{
        workspace_settings: file_status(WorkspaceSettings.path(workspace)),
        global_settings: %{
          location_source:
            if(System.get_env("HANDBEAM_GLOBAL_SETTINGS_FILE"),
              do: :environment_override,
              else: :global_dir_or_home
            ),
          file: file_status(Settings.global_settings_path(opts))
        }
      },
      prompt: %{
        environment_sections: HostEnvironment.sections(),
        source: :agent_config_build_system_prompt,
        custom_prompt: :environment_appended,
        final_request: :unknown,
        reason: :context_skills_memory_and_hooks_are_not_evaluated,
        script_details_source: :tool_script_environment,
        body: :withheld
      },
      security: %{
        secrets_and_free_text: :withheld,
        authorization: :unknown_without_call_and_run,
        boundary: :tool_path_checks_and_tool_guard_not_a_sandbox
      }
    }
  end

  defp capabilities do
    raw = Application.get_env(:handbeam, :host, %{})

    Map.new(@capabilities, fn key ->
      value = apply(Host, String.to_existing_atom("#{key}?"), [])

      source =
        cond do
          key == :webview_browser and Host.desktop_browser?() -> :desktop_browser_precedence
          key == :system_intents and not is_boolean(raw[key]) -> :webview_browser_fallback
          Map.has_key?(raw, key) -> :application_host
          key in [:mcp, :dist] -> :host_build_environment_default
          true -> :host_default
        end

      {key, %{configured: value == true, source: source}}
    end)
  end

  defp tool(seed, registered) do
    name = seed.module.name()

    %{
      name: name,
      configured: seed.enabled,
      source: seed.source,
      disabled_reason: if(seed.enabled, do: nil, else: :host_capability_disabled),
      registered: if(is_list(registered), do: name in registered, else: :unknown),
      dependency_available: :unknown,
      run_authorized: :unknown
    }
  end

  defp registered_names do
    if Process.whereis(Registry), do: Registry.list(), else: :unknown
  catch
    :exit, _ -> :unknown
  end

  defp registry_summary(:unknown, _),
    do: %{status: :unknown, reason: :registry_not_running_or_unreachable}

  defp registry_summary(names, seeds) do
    seed_names = Enum.map(seeds, & &1.module.name())

    %{
      status: :observed,
      total: length(names),
      additional_count: length(names -- seed_names),
      additional_names: :withheld
    }
  end

  defp dependency(false, _),
    do: %{
      configured: false,
      executable_found: :not_checked,
      operational: :unknown,
      reason: :host_capability_disabled
    }

  defp dependency(true, binary) do
    found = not is_nil(System.find_executable(binary))

    %{
      configured: true,
      executable_found: found,
      operational: :unknown,
      reason: if(found, do: :not_executed, else: :executable_missing)
    }
  end

  defp code_index(workspace) do
    embeddings = Handbeam.CodeIndex.embeddings_configured?()

    case Handbeam.WorkspaceStore.get_by_path(workspace) do
      {:ok, %{"id" => id}} when is_binary(id) ->
        case Handbeam.CodeIndex.status(workspace, id) do
          {:ok, %{exists: exists}} ->
            %{index_present: exists, embeddings_configured: embeddings}

          {:error, _} ->
            %{index_present: :unknown, embeddings_configured: embeddings}
        end

      _ ->
        %{index_present: false, embeddings_configured: embeddings, workspace: :unregistered}
    end
  end

  defp git_backend do
    if Code.ensure_loaded?(Handbeam.Git) and function_exported?(Handbeam.Git, :backend_kind, 0) do
      %{
        backend: apply(Handbeam.Git, :backend_kind, []),
        source: :host_default,
        operational: :unknown,
        reason: :not_probed
      }
    else
      %{backend: :libgit2_not_shell, operational: :unknown}
    end
  end

  defp shell_backend do
    # ShellResolver also reads overrides and absolute fallback paths; on Windows
    # it can execute `where`. A PATH lookup alone must not claim shell availability.
    if Host.shell?() do
      %{
        configured: true,
        bash_in_path: not is_nil(System.find_executable("bash")),
        source_of_truth: :platform_shell_resolver,
        dependency_available: :unknown,
        operational: :unknown,
        reason: :settings_and_fallback_paths_not_resolved
      }
    else
      dependency(false, "bash")
    end
  end

  defp mix_project_backend do
    if Host.packaged_mix_toolchain?() do
      %{configured: true, backend: :packaged_host_beam_not_shell, toolchain: toolchain()}
    else
      %{
        configured: false,
        backend: :system_mix_via_shell,
        dependency_available: :unknown,
        reason: :desktop_uses_host_path
      }
    end
  end

  defp toolchain do
    case Handbeam.Workspace.MixToolchain.info() do
      {:ok, info} -> Map.take(info, [:mix?, :hex?, :ex_unit?, :source])
      {:error, _} -> %{status: :unavailable, reason: :missing_or_incompatible_toolchain}
    end
  end

  defp endpoint_server do
    Application.get_env(:handbeam, HandbeamWeb.Endpoint, []) |> Keyword.get(:server, false) ==
      true
  end

  defp approval({:error, _}),
    do: %{
      status: :workspace_settings_error,
      effective_default: ToolPolicy.from_settings(%{}).default_mode,
      source: :tool_policy_error_fallback,
      call_decision: :unknown
    }

  defp approval({:ok, settings}) do
    policy = ToolPolicy.from_settings(settings)
    tools = settings["tools"]
    mode = if is_map(tools), do: tools["default_mode"]

    %{
      effective_default: policy.default_mode,
      source:
        if(Handbeam.Permissions.ApprovalMode.valid?(mode),
          do: :workspace_tools_default_mode,
          else: :tool_policy_default
        ),
      allow_rules: length(policy.allow),
      deny_rules: length(policy.deny),
      per_tool_rules: map_size(policy.per_tool),
      mcp_rules: map_size(policy.mcp),
      call_decision: :unknown,
      reason: :requires_arguments_session_overrides_and_capability_rules,
      source_of_truth: :permissions_tool_policy
    }
  end

  defp model_ai(workspace, opts) do
    case Settings.inspect_model_ai(workspace, opts) do
      {:ok, %{settings: settings, sources: sources}} ->
        Map.new(Map.from_struct(settings), fn {key, value} ->
          {key, %{value: safe_setting(key, value), source: sources[key]}}
        end)

      {:error, _} ->
        %{
          status: :workspace_settings_error,
          source: :settings_effective_model_ai_defaults_fallback
        }
    end
  rescue
    # JSON can parse successfully but have a shape rejected by the existing
    # settings normalizer. Do not emit exceptions containing user-controlled data.
    _ in [FunctionClauseError, BadMapError] ->
      %{status: :invalid_settings_shape, effective: :unknown}
  end

  defp safe_setting(_, value) when is_boolean(value) or is_number(value) or is_nil(value),
    do: value

  defp safe_setting(:reasoning, value) when value in ~w(off minimal low medium high xhigh),
    do: value

  defp safe_setting(:om_memory_scope, value) when value in ~w(workspace conversation), do: value
  defp safe_setting(:om_privacy_mode, value) when value in ~w(standard strict), do: value
  defp safe_setting(_, _), do: :withheld

  defp model_catalog do
    %{
      location_source:
        if(System.get_env("HANDBEAM_MODELS_FILE") in [nil, ""],
          do: :host_home,
          else: :environment_override
        ),
      file: file_status(ModelConfig.config_file_path()),
      status:
        case ModelConfig.read_config() do
          {:ok, _} -> :readable_or_missing
          {:error, _} -> :invalid_or_unreadable
        end,
      runtime_overrides:
        Map.new(
          ~w(OPENAI_BASE_URL OPENAI_MODEL OPENAI_MAX_TOKENS OPENAI_TEMPERATURE),
          &{&1, not is_nil(System.get_env(&1))}
        ),
      provider_precedence: [
        :explicit_runtime_options,
        :non_secret_environment_overrides,
        :catalog,
        :built_in_defaults
      ],
      selected_run_model: :unknown,
      credentials: :not_resolved,
      note: :entry_points_resolve_workspace_model_policy_before_agent_config
    }
  end

  defp file_status(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> :present
      {:ok, _} -> :not_regular
      {:error, :enoent} -> :missing
      {:error, _} -> :unreadable
    end
  end
end

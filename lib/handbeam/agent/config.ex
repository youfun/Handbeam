defmodule Handbeam.Agent.Config do
  @moduledoc """
  Agent configuration struct.

  Holds provider, tools, middleware, and runtime settings.
  """

  alias Handbeam.Memory.{Policy, PromptPolicy}
  alias Handbeam.Agent.ContextLoader
  alias Handbeam.Skills.{Loader, PromptFormatter}

  require Logger

  # Module attributes used as defaults (defined before defstruct to allow use in struct default)
  @default_context %{}
  @default_tool_timeout 60_000

  defstruct [
    :provider,
    :system_prompt,
    :working_directory,
    :model,
    :max_turns,
    :max_budget_cents,
    :timeout_ms,
    :until_tool,
    :reasoning_level,
    :memory,
    :middleware,
    :provider_config,
    :max_messages,
    :max_tokens,
    :compaction,
    :on_compaction,
    context: @default_context,
    tool_timeout: @default_tool_timeout
  ]

  @type t :: %__MODULE__{
          provider: module(),
          system_prompt: String.t() | nil,
          working_directory: String.t(),
          model: String.t(),
          max_turns: pos_integer(),
          max_budget_cents: pos_integer() | nil,
          timeout_ms: pos_integer(),
          tool_timeout: pos_integer(),
          until_tool: String.t() | nil,
          reasoning_level: String.t(),
          memory: module() | nil,
          context: map(),
          middleware: [module()] | nil,
          provider_config: map(),
          max_messages: pos_integer(),
          max_tokens: pos_integer(),
          compaction: %{
            reserve_tokens: pos_integer(),
            keep_recent_tokens: pos_integer(),
            fallback: :truncate
          },
          on_compaction: (list(), t() -> any()) | nil
        }

  @default_model "step-router-v1"
  @default_max_turns 50
  @default_timeout_ms 300_000
  @default_max_messages 200
  @default_max_tokens 200_000
  @default_compaction %{reserve_tokens: 16_384, keep_recent_tokens: 20_000, fallback: :truncate}

  @doc """
  Build configuration from keyword options.

  Provider selection priority:
    1. Explicit `:provider` module in opts
    2. `provider_config[:provider]` → maps "stepfun" to StepFun, "openai" to OpenAI Responses, "openai-compat" to OpenAICompat
    3. Default → `Handbeam.Agent.Provider.OpenAICompat`
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts \\ []) do
    provider_config = Keyword.get(opts, :provider_config, %{})

    provider =
      Keyword.get(opts, :provider) ||
        resolve_provider_from_api(
          provider_config[:api],
          Keyword.get(opts, :model),
          provider_config[:provider]
        )

    %__MODULE__{
      provider: provider,
      system_prompt: build_system_prompt(opts),
      working_directory: Keyword.get(opts, :working_directory, File.cwd!()),
      model: Keyword.get(opts, :model, @default_model),
      max_turns: Keyword.get(opts, :max_turns, @default_max_turns),
      max_budget_cents: Keyword.get(opts, :max_budget_cents),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      tool_timeout: Keyword.get(opts, :tool_timeout, @default_tool_timeout),
      until_tool: Keyword.get(opts, :until_tool),
      reasoning_level:
        Keyword.get(
          opts,
          :reasoning_level,
          Handbeam.Settings.ModelAISettings.defaults().reasoning
        ),
      memory: Keyword.get(opts, :memory),
      context: build_context(opts),
      middleware: Keyword.get(opts, :middleware, default_middleware()),
      provider_config: provider_config,
      max_messages: Keyword.get(opts, :max_messages, @default_max_messages),
      max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
      compaction: build_compaction(opts),
      on_compaction: Keyword.get(opts, :on_compaction)
    }
  end

  @doc """
  Resolve provider module from model configuration.

  Mapping:
    - `provider_config[:provider] == "zenmux"` → `Handbeam.Agent.Provider.ZenMux`
    - `provider_config[:provider] == "openrouter"` → `Handbeam.Agent.Provider.OpenRouter`
    - `provider_config[:provider] == "deepseek"` → `Handbeam.Agent.Provider.DeepSeek`
    - `provider_config[:api] == :anthropic` → `Handbeam.Agent.Provider.Anthropic`
      (even when the provider key is StepFun/Step Plan; this is the
      Anthropic Messages wire protocol)
    - `provider_config[:provider] == "stepfun"` → `Handbeam.Agent.Provider.StepFun`
    - `provider_config[:api] == :stepfun` → `Handbeam.Agent.Provider.StepFun`
    - `provider_config[:provider] == "openai"` → `Handbeam.Agent.Provider.OpenAI`
    - `provider_config[:api] == :openai_responses` → `Handbeam.Agent.Provider.OpenAI`
    - `provider_config[:api] == :anthropic` → `Handbeam.Agent.Provider.Anthropic`
    - `provider_config[:provider] == "openai-compat"` → `Handbeam.Agent.Provider.OpenAICompat`
    - default → `Handbeam.Agent.Provider.OpenAICompat`
  """
  @spec resolve_provider_from_api(atom() | nil, String.t() | nil, String.t() | nil) :: module()
  def resolve_provider_from_api(:anthropic, _model, _provider),
    do: Handbeam.Agent.Provider.Anthropic

  def resolve_provider_from_api(_api, _model, "zenmux"), do: Handbeam.Agent.Provider.ZenMux

  def resolve_provider_from_api(_api, _model, "openrouter"),
    do: Handbeam.Agent.Provider.OpenRouter

  def resolve_provider_from_api(_api, _model, "deepseek"), do: Handbeam.Agent.Provider.DeepSeek
  def resolve_provider_from_api(_api, _model, "stepfun"), do: Handbeam.Agent.Provider.StepFun

  def resolve_provider_from_api(_api, _model, "openai-compat"),
    do: Handbeam.Agent.Provider.OpenAICompat

  def resolve_provider_from_api(_api, _model, "openai"), do: Handbeam.Agent.Provider.OpenAI
  def resolve_provider_from_api(:stepfun, _model, _provider), do: Handbeam.Agent.Provider.StepFun

  def resolve_provider_from_api(:openai_responses, _model, _provider),
    do: Handbeam.Agent.Provider.OpenAI

  def resolve_provider_from_api(_api, _model, _provider), do: Handbeam.Agent.Provider.OpenAICompat

  defp build_context(opts) do
    opts
    |> Keyword.get(:context, @default_context)
    |> Map.merge(%{
      workspace_id: Keyword.get(opts, :workspace_id),
      conversation_id: Keyword.get(opts, :conversation_id),
      run_id: Keyword.get(opts, :run_id),
      thread_handoff_id: get_in(Keyword.get(opts, :origin) || %{}, ["handoff_id"]),
      delegated_read_only: Keyword.get(opts, :delegated_read_only, false),
      memory_scope: get_in(Keyword.get(opts, :om, %{}), [:memory_scope]),
      privacy_mode: get_in(Keyword.get(opts, :om, %{}), [:privacy_mode])
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp build_system_prompt(opts) do
    base =
      Keyword.get_lazy(opts, :system_prompt, fn ->
        default_system_prompt()
      end)

    base
    |> maybe_inject_workspace_contract(opts)
    |> maybe_inject_project_context(opts)
    |> maybe_inject_skills(opts)
    |> maybe_append_task_instructions(opts)
  end

  defp maybe_append_task_instructions(system_prompt, opts) do
    case Keyword.get(opts, :task_instructions) do
      text when is_binary(text) ->
        case String.trim(text) do
          "" ->
            system_prompt

          trimmed ->
            append_prompt_section(
              system_prompt,
              "\n\n## Task instructions\n\n" <> trimmed <> "\n"
            )
        end

      _ ->
        system_prompt
    end
  end

  defp maybe_inject_workspace_contract(system_prompt, opts) do
    if Keyword.has_key?(opts, :system_prompt) do
      system_prompt
    else
      working_directory = Keyword.get(opts, :working_directory, File.cwd!())

      system_prompt <>
        """

        ## Current Workspace

        Current workspace: #{working_directory}

        #{workspace_tool_contract(working_directory)}
        """
    end
  end

  defp workspace_tool_contract(working_directory) do
    tools =
      cond do
        Handbeam.Host.shell?() ->
          "`read`, `edit`, `write`, `bash`, `file_search`"

        Handbeam.Host.system_intents?() ->
          "`read`, `edit`, `write`, `grep`, `file_search`, `run_elixir_script`"

        true ->
          "`read`, `edit`, `write`, `grep`, `file_search`"
      end

    extra =
      cond do
        Handbeam.Host.shell?() ->
          "The `bash` tool runs commands from the current workspace by default. Do not prefix commands with `cd #{working_directory} &&`; call the command directly, or set the `cwd` argument only when you need to run inside a subdirectory of the workspace."

        true ->
          no_shell_contract()
      end

    """
    Prefer workspace-relative file paths in tool calls (#{tools}), for example `workspace-check.txt` or `reports/summary.md`. Relative paths are joined with the current workspace root; do not prepend the workspace directory name. The workspace root is NOT the filesystem root `/`: `/workspace-check.txt` refers to the filesystem root, not this workspace. Absolute and `~`-expanded paths remain subject to tool path permissions; use paths inside the current workspace for generated files.

    #{extra}
    """
  end

  defp maybe_inject_project_context(system_prompt, opts) do
    # If the user explicitly provided a system_prompt, skip context injection
    # (they get full control). Otherwise, inject AGENTS.md context.
    if Keyword.has_key?(opts, :system_prompt) do
      system_prompt
    else
      paths = ContextLoader.discover(Keyword.get(opts, :working_directory, File.cwd!()))
      {:ok, context} = ContextLoader.load(paths)
      {context, _truncated?} = ContextLoader.truncate(context)
      ContextLoader.inject(system_prompt, context)
    end
  end

  defp maybe_inject_skills(system_prompt, opts) do
    cond do
      not Keyword.get(opts, :skills, false) ->
        system_prompt

      Keyword.has_key?(opts, :system_prompt) and
          not Keyword.get(opts, :inject_skills_into_custom_prompt, false) ->
        system_prompt

      true ->
        opts
        |> load_skills()
        |> PromptFormatter.format_available_skills()
        |> then(&append_prompt_section(system_prompt, &1))
    end
  end

  defp load_skills(opts) do
    working_directory = Keyword.get(opts, :working_directory, File.cwd!())

    default_result = Loader.load(workspace: working_directory)

    explicit_result =
      opts
      |> Keyword.get(:skill_paths, [])
      |> List.wrap()
      |> Enum.reduce(%Loader.LoadResult{}, fn path, acc ->
        Loader.merge_result(acc, Loader.load_from_dir(path, :explicit))
      end)

    result = Loader.merge_result(default_result, explicit_result)
    log_skill_diagnostics(result.diagnostics)

    result.skills
  end

  defp log_skill_diagnostics(diagnostics) do
    Enum.each(diagnostics, fn diagnostic ->
      level = if diagnostic[:type] == :error, do: :warning, else: :info
      path = Map.get(diagnostic, :path, "unknown path")
      message = Map.get(diagnostic, :message, inspect(diagnostic))

      Logger.log(level, "[Skills] #{message} (#{path})")
    end)
  end

  defp append_prompt_section(system_prompt, ""), do: system_prompt
  defp append_prompt_section(system_prompt, section), do: system_prompt <> section

  defp build_compaction(opts) do
    raw = Keyword.get(opts, :compaction, %{}) |> Enum.into(%{})

    %{
      reserve_tokens: Map.get(raw, :reserve_tokens, @default_compaction.reserve_tokens),
      keep_recent_tokens:
        Map.get(raw, :keep_recent_tokens, @default_compaction.keep_recent_tokens),
      fallback: Map.get(raw, :fallback, @default_compaction.fallback)
    }
  end

  defp default_system_prompt do
    memory_section = PromptPolicy.generate(%Policy{profile: :balanced})

    """
    You are Handbeam, an AI coding assistant. You help users by reading files,
    executing commands, editing code, and writing new files.

    ## Workflow

    Before making changes, follow this process to minimize turns:

    1. **Read First**: Read the relevant source and test files needed to understand
       the task before writing any code.
    2. **Plan**: Identify all issues or requirements, then decide on a single
       comprehensive approach.
    3. **Batch Changes**: Apply related changes together. Use `edit` for small,
       precise updates; use `write` to rewrite a whole file when the file is small
       or the changes are broad enough that a full rewrite is clearer and safer
       than many separate edits.
    4. **Verify**: After making changes, immediately run tests or the relevant command
       to confirm correctness. If it fails, read the error output carefully before
       making further changes.

    ## Tool Rules

    1. **Workspace**: All file paths must stay inside the working directory.
    2. **Read**: Use `read` to inspect files. Never guess file contents.
    3. **Write**: Use `write` only for new files or complete rewrites.
    4. **Edit**: Use `edit` for precise changes with exact text replacement.
       When making multiple changes to the same file, use one `edit` call with the
       `edits` array containing multiple `{old_string, new_string}` entries instead
       of multiple separate `edit` calls. Each `edits[].old_string` is matched
       against the original file, not incrementally. Keep each `old_string` minimal
       and unique; merge nearby changes into one entry.
    #{tool_rule_five()}
    6. **Edit Failures**: If an `edit` fails because old_string does not match, re-read
       the file to get the current exact text, then retry with the correct old_string.
       Do not abandon the task — adjust and try again.
    """ <> "\n\n" <> String.trim_trailing(memory_section) <> "\n"
  end

  defp tool_rule_five do
    if Handbeam.Host.shell?() do
      """
      5. **Bash**: Only use `bash` for safe, necessary operations. Prefer read/edit/write
         for file operations, and use `grep` for content search.
      """
      |> String.trim()
    else
      """
      5. **No shell**: Do not call `bash`. Search local files with `grep`/`file_search`.
      #{no_shell_script_rule()}
      """
      |> String.trim()
    end
  end

  defp no_shell_contract do
    "There is no Unix shell on this host. Do not call `bash`. Use only tools provided in this request; browser availability is independent of shell access." <>
      no_shell_script_rule()
  end

  defp no_shell_script_rule do
    if Handbeam.Host.system_intents?() do
      " For local computation, file processing or HTTP, use `run_elixir_script` when exposed. When Mix is present, install host-compatible pure Elixir/Erlang Hex packages with Mix.install/2 inside the .exs (top of the script, before using those modules). Follow the script tool environment for Mix/Hex availability; write the script, execute it and verify outputs. Treat it as high-privilege host BEAM code."
    else
      ""
    end
  end

  defp default_middleware do
    base = [
      Handbeam.Agent.Middleware.Logger,
      Handbeam.Agent.Middleware.Security,
      Handbeam.Agent.Middleware.ToolGuard
    ]

    # Prepend OM middleware when enabled (so they run before other hooks)
    om_modules = Handbeam.Memory.ObservationalConfig.middleware_modules()
    om_modules ++ base
  end
end

defmodule Handbeam.Permissions.ToolPolicy do
  @moduledoc """
  Compiled workspace tool permission policy.
  """

  alias Handbeam.Browser.Policy, as: BrowserPolicy
  alias Handbeam.Permissions.{ApprovalMode, Matcher}

  defstruct default_mode: :auto,
            allow: [],
            deny: [],
            per_tool: %{},
            mcp: %{},
            overrides: %{}

  @type t :: %__MODULE__{
          default_mode: ApprovalMode.t(),
          allow: [String.t()],
          deny: [String.t()],
          per_tool: %{String.t() => ApprovalMode.t()},
          mcp: %{String.t() => ApprovalMode.t()},
          overrides: %{String.t() => ApprovalMode.t()}
        }

  @spec from_workspace(Path.t(), map()) :: t()
  def from_workspace(workspace_root, overrides \\ %{}) do
    settings =
      case Handbeam.WorkspaceSettings.load(workspace_root) do
        {:ok, settings} -> settings
        {:error, _reason} -> %{}
      end

    from_settings(settings, overrides)
  end

  @spec from_settings(map(), map()) :: t()
  def from_settings(settings, overrides \\ %{}) when is_map(settings) do
    tools = Map.get(settings, "tools", %{})
    tools = if is_map(tools), do: tools, else: %{}

    %__MODULE__{
      default_mode: ApprovalMode.parse(Map.get(tools, "default_mode"), :auto),
      allow: string_list(Map.get(tools, "allow", [])),
      deny: string_list(Map.get(tools, "deny", [])),
      per_tool: parse_mode_map(Map.get(tools, "per_tool", %{})),
      mcp: parse_mode_map(Map.get(tools, "mcp", %{})),
      overrides: normalize_overrides(overrides)
    }
  end

  @builtin_prompt_tools MapSet.new(["ext__term_send"])
  @mount_prompt_tools MapSet.new(["ext__mount__apply", "ext__mount__drop"])

  @spec decision(t(), map()) :: ApprovalMode.t()
  def decision(%__MODULE__{} = policy, call) when is_map(call) do
    name = to_string(call[:name] || call["name"] || "")

    cond do
      Map.get(policy.overrides, name) == :deny ->
        :deny

      Enum.any?(policy.deny, &Matcher.match?(&1, call)) ->
        :deny

      # Allow rules and session grants were given for sandboxed execution;
      # leaving the OS sandbox is always a fresh decision.
      unsandboxed_bash?(name, call) ->
        if policy.default_mode == :deny, do: :deny, else: :prompt

      # Applying a subagent worktree writes an unreviewed diff into the workspace.
      worktree_apply?(name, call) ->
        if policy.default_mode == :deny, do: :deny, else: :prompt

      Map.has_key?(policy.per_tool, name) ->
        Map.fetch!(policy.per_tool, name)

      Map.has_key?(policy.overrides, name) ->
        Map.fetch!(policy.overrides, name)

      mcp_mode = mcp_decision(policy, name) ->
        mcp_mode

      Enum.any?(policy.allow, &Matcher.match?(&1, call)) ->
        :auto

      browser_mode = browser_decision(policy, name, call) ->
        browser_mode

      bash_browser_mode = bash_browser_decision(name, call) ->
        bash_browser_mode

      capability_prompt?(policy, name) ->
        :prompt

      true ->
        policy.default_mode
    end
  end

  # Full access (`default_mode: :auto`) means capability-level prompts do not
  # interrupt. Capability denies (local file URLs, bash wrapping agent-browser)
  # still apply. Safe mode (`:prompt`) and read-only (`:deny`) keep asking.
  # Host-privileged script execution and system UI (system browser,
  # open/share exported files) ask even in full-access workspaces.
  # Deny, per_tool, session overrides, and allow-list/always-allow stay above
  # this, so "allow for this session" / "always allow" are honored for them.
  defp capability_prompt?(_policy, "run_elixir_script"), do: true
  defp capability_prompt?(_policy, "mix_project"), do: true

  defp capability_prompt?(%__MODULE__{default_mode: :auto}, name) do
    name in Handbeam.ArtifactDelivery.tool_names()
  end

  defp capability_prompt?(_policy, name) do
    name in Handbeam.ArtifactDelivery.tool_names() or
      MapSet.member?(@builtin_prompt_tools, name) or
      MapSet.member?(@mount_prompt_tools, name)
  end

  defp browser_decision(%__MODULE__{} = policy, "browser", call) do
    case classify_browser_call(call) do
      {:auto, _} -> nil
      {:prompt, _} when policy.default_mode == :auto -> nil
      {:prompt, _} -> :prompt
      {:deny, _} -> :deny
    end
  end

  defp browser_decision(_policy, _name, _call), do: nil

  defp bash_browser_decision("bash", call) do
    command = bash_command(call)

    if agent_browser_command?(command) do
      :deny
    end
  end

  defp bash_browser_decision(_name, _call), do: nil

  defp unsandboxed_bash?("bash", call) do
    input = call[:input] || call["input"] || %{}
    Map.get(input, "unsandboxed") == true or Map.get(input, :unsandboxed) == true
  end

  defp unsandboxed_bash?(_name, _call), do: false

  defp worktree_apply?("task_status", call) do
    input = call[:input] || call["input"] || %{}
    (Map.get(input, "action") || Map.get(input, :action)) == "apply"
  end

  defp worktree_apply?(_name, _call), do: false

  defp bash_command(call) when is_map(call) do
    input = call[:input] || call["input"] || %{}
    Map.get(input, "command") || Map.get(input, :command) || ""
  end

  defp agent_browser_command?(command) when is_binary(command) do
    String.match?(command, ~r/(^|[;&|`\n]|&&|\|\|)\s*(npx\s+)?agent-browser(\s|$)/)
  end

  defp agent_browser_command?(_), do: false

  defp classify_browser_call(call) when is_map(call) do
    input = call[:input] || call["input"] || %{}

    if Handbeam.Tool.Builtin.Browser.backend() == :webview do
      BrowserPolicy.classify_native(input)
    else
      args = Map.get(input, "args") || Map.get(input, :args) || []
      BrowserPolicy.classify(args)
    end
  end

  defp mcp_decision(%__MODULE__{mcp: mcp}, name) do
    cond do
      Map.has_key?(mcp, name) ->
        Map.fetch!(mcp, name)

      match =
          Enum.find(mcp, fn {pattern, _mode} ->
            Matcher.match?(pattern, %{name: name, input: %{}})
          end) ->
        elem(match, 1)

      true ->
        nil
    end
  end

  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_), do: []

  defp parse_mode_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), ApprovalMode.parse(value, :auto)} end)
  end

  defp parse_mode_map(_), do: %{}

  defp normalize_overrides(overrides) when is_map(overrides) do
    Map.new(overrides, fn {key, value} -> {to_string(key), ApprovalMode.parse(value, :auto)} end)
  end

  defp normalize_overrides(_), do: %{}
end

defmodule Handbeam.Browser.Policy do
  @moduledoc """
  Classifies `browser` argv before any subprocess is spawned.

  Safe page interaction can follow the workspace default mode. Sensitive
  families require approval. Local files, caller-owned sessions, and
  shell metacharacters are denied.
  """

  @type capability ::
          :navigation
          | :inspect
          | :interact
          | :eval
          | :cookies
          | :storage
          | :auth
          | :upload
          | :download
          | :profile
          | :headed
          | :connect
          | :cdp
          | :unknown

  @type meta :: %{
          optional(:command) => String.t(),
          optional(:capability) => capability(),
          optional(:reason) => String.t(),
          optional(:failure_category) => String.t()
        }

  @type decision :: {:auto, meta()} | {:prompt, meta()} | {:deny, meta()}

  @auto_commands MapSet.new([
                   "open",
                   "goto",
                   "navigate",
                   "snapshot",
                   "click",
                   "dblclick",
                   "fill",
                   "type",
                   "press",
                   "hover",
                   "scroll",
                   "scrollintoview",
                   "get",
                   "is",
                   "find",
                   "select",
                   "check",
                   "uncheck",
                   "focus",
                   "tab",
                   "wait",
                   "screenshot",
                   "read",
                   "back",
                   "forward",
                   "reload"
                 ])

  @prompt_commands %{
    "eval" => :eval,
    "cookies" => :cookies,
    "storage" => :storage,
    "auth" => :auth,
    "upload" => :upload,
    "download" => :download,
    "connect" => :connect,
    "pdf" => :download,
    "keyboard" => :interact,
    "session" => :profile,
    "network" => :connect,
    "set" => :auth
  }

  @inspection_flags ["--help", "-h", "--version", "-V"]
  @navigation_commands MapSet.new(["open", "goto", "navigate"])
  @native_actions MapSet.new(~w(open snapshot eval click fill back show hide close))

  @doc """
  Classify caller args into `:auto`, `:prompt`, or `:deny`.
  """
  @spec classify(term()) :: decision()
  def classify(args) when not is_list(args) do
    deny("args must be a list of strings")
  end

  def classify([]) do
    deny("args must be a non-empty list of strings")
  end

  def classify(args) do
    cond do
      not Enum.all?(args, &is_binary/1) ->
        deny("args must be a list of strings")

      forbidden_token = Enum.find(args, &forbidden_token?/1) ->
        deny("blocked token: #{forbidden_token}")

      shell_arg = Enum.find(args, &shell_injection?/1) ->
        deny("shell metacharacters are not allowed: #{inspect(shell_arg)}")

      true ->
        classify_command(args)
    end
  end

  @doc "True when the call is a stateless inspection command."
  @spec inspection?([String.t()]) :: boolean()
  def inspection?(args) when is_list(args) do
    command(args) in @inspection_flags
  end

  def inspection?(_), do: false

  @doc """
  Classify native structured browser input (`action` / `url` / `js` / `ref`).

  Desktop CLI policy must keep using `classify/1` on `args`. This path is
  only for the WebView host schema.
  """
  @spec classify_native(term()) :: decision()
  def classify_native(input) when not is_map(input) do
    deny("native browser input must be a map")
  end

  def classify_native(input) do
    classify_native_action(input)
  end

  @doc """
  Command token used by workspace deny/allow globs.

  Desktop uses the first `args` entry. WebView uses `action` and never
  falls back to injecting `action` into argv.
  """
  @spec command_token(map()) :: String.t()
  def command_token(input) when is_map(input) do
    args = Map.get(input, "args") || Map.get(input, :args)

    if Handbeam.Host.webview_browser?() or is_nil(args) do
      case native_field(input, "action") do
        action when is_binary(action) -> action
        _ -> ""
      end
    else
      case args do
        [first | _] when is_binary(first) -> first
        _ -> ""
      end
    end
  end

  def command_token(_), do: ""

  @doc "First non-flag token, or a leading inspection flag."
  @spec command([String.t()]) :: String.t() | nil
  def command(args) when is_list(args) do
    Enum.find(args, fn
      flag when flag in @inspection_flags -> true
      <<"-" <> _::binary>> -> false
      _ -> true
    end)
  end

  def command(_), do: nil

  defp classify_command(args) do
    cmd = command(args)

    cond do
      is_nil(cmd) ->
        deny("missing browser command")

      cmd in @inspection_flags ->
        {:auto, %{command: cmd, capability: :inspect}}

      prompt_flag = prompt_flag_capability(args) ->
        {:prompt, %{command: cmd, capability: prompt_flag}}

      Map.has_key?(@prompt_commands, cmd) ->
        {:prompt, %{command: cmd, capability: Map.fetch!(@prompt_commands, cmd)}}

      cmd in @navigation_commands ->
        classify_navigation(cmd, args)

      cmd in ["close", "quit"] ->
        classify_close(cmd, args)

      cmd in @auto_commands ->
        {:auto, %{command: cmd, capability: :interact}}

      true ->
        {:prompt, %{command: cmd, capability: :unknown}}
    end
  end

  defp classify_navigation(cmd, args) do
    case navigation_url(args) do
      {:ok, url} ->
        if private_or_local_url?(url) do
          {:prompt, %{command: cmd, capability: :navigation, reason: "local or private URL"}}
        else
          {:auto, %{command: cmd, capability: :navigation}}
        end

      {:error, reason} ->
        deny(reason)
    end
  end

  defp classify_close(cmd, args) do
    if has_flag?(args, "--all") do
      {:prompt,
       %{command: cmd, capability: :profile, reason: "close --all affects every session"}}
    else
      {:auto, %{command: cmd, capability: :interact}}
    end
  end

  defp navigation_url(args) do
    case Enum.find(args, &http_or_other_url?/1) do
      nil ->
        {:error, "navigation requires an http(s) URL"}

      url ->
        if http_url?(url) do
          {:ok, url}
        else
          {:error, "only http(s) URLs are allowed: #{url}"}
        end
    end
  end

  defp http_or_other_url?(value) when is_binary(value) do
    String.contains?(value, "://") or String.starts_with?(value, "about:")
  end

  defp http_or_other_url?(_), do: false

  defp classify_native_action(input) do
    action = native_field(input, "action")

    cond do
      not is_binary(action) or action == "" ->
        deny("action is required")

      action not in @native_actions ->
        deny("unsupported browser action: #{action}")

      action == "open" ->
        classify_native_open(input)

      action == "eval" ->
        {:prompt, %{command: "eval", capability: :eval}}

      takeover?(input) ->
        {:prompt, %{command: action, capability: :profile, reason: "user takeover"}}

      true ->
        {:auto, %{command: action, capability: :interact}}
    end
  end

  defp classify_native_open(input) do
    case native_field(input, "url") do
      url when is_binary(url) and url != "" ->
        if http_url?(url) do
          if private_or_local_url?(url) do
            {:prompt, %{command: "open", capability: :navigation, reason: "local or private URL"}}
          else
            {:auto, %{command: "open", capability: :navigation}}
          end
        else
          deny("only http(s) URLs are allowed: #{url}")
        end

      _ ->
        deny("navigation requires an http(s) URL")
    end
  end

  defp takeover?(input) do
    native_field(input, "takeover") in [true, "true"]
  end

  defp native_field(input, key) when is_map(input) and is_binary(key) do
    Map.get(input, key) || Map.get(input, native_atom(key))
  end

  defp native_atom("action"), do: :action
  defp native_atom("url"), do: :url
  defp native_atom("js"), do: :js
  defp native_atom("ref"), do: :ref
  defp native_atom("value"), do: :value
  defp native_atom("text"), do: :text
  defp native_atom("reason"), do: :reason
  defp native_atom("takeover"), do: :takeover
  defp native_atom(_), do: nil

  defp http_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        is_binary(host) and host != ""

      _ ->
        false
    end
  end

  defp private_or_local_url?(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        host = String.downcase(host)

        host in ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"] or
          String.starts_with?(host, "169.254.") or
          String.starts_with?(host, "10.") or
          String.match?(host, ~r/^192\.168\./) or
          String.match?(host, ~r/^172\.(1[6-9]|2\d|3[0-1])\./)

      _ ->
        false
    end
  end

  defp forbidden_token?("--json"), do: true
  defp forbidden_token?("--session"), do: true
  defp forbidden_token?("--namespace"), do: true
  defp forbidden_token?("--allow-file-access"), do: true
  defp forbidden_token?("--session=" <> _), do: true
  defp forbidden_token?("--namespace=" <> _), do: true
  defp forbidden_token?("--allow-file-access=" <> _), do: true
  defp forbidden_token?(_), do: false

  defp prompt_flag_capability(args) do
    cond do
      has_flag?(args, "--profile") -> :profile
      has_flag?(args, "--headed") -> :headed
      has_flag?(args, "--cdp") -> :cdp
      true -> nil
    end
  end

  defp has_flag?(args, flag) do
    prefix = flag <> "="
    Enum.any?(args, fn arg -> arg == flag or String.starts_with?(arg, prefix) end)
  end

  defp shell_injection?(arg) when is_binary(arg) do
    String.contains?(arg, ["&&", "||", "$(", "`", "\n"]) or
      (String.contains?(arg, [";", "|", ">", "<"]) and looks_like_shell_pipeline?(arg))
  end

  defp shell_injection?(_), do: false

  defp looks_like_shell_pipeline?(arg) do
    String.match?(arg, ~r/(?:^|[\s;|&])(?:rm|cat|curl|wget|bash|sh|zsh|python|perl|nc)\b/)
  end

  defp deny(reason) do
    {:deny, %{failure_category: "validation-error", reason: reason}}
  end
end

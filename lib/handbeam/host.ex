defmodule Handbeam.Host do
  @moduledoc """
  Values the host writes once at boot. Handbeam does not parse MOB_* here.

  Desktop Mix never sets `:host`, so readers fall back to HOME / app_dir.
  `webview_browser` and `desktop_browser` are mutually exclusive: if both
  are set true, desktop CLI browser wins and `webview_browser?/0` is false.

  `system_intents` says the host can launch system UI (system browser,
  open/share an exported artifact via FileProvider) and run host-privileged
  `.exs` scripts in place of a shell. When the host does not declare it,
  `system_intents?/0` falls back to `webview_browser?/0` so existing phone
  hosts keep their Android tools.

  `directory_picker` is an optional callback (`fun/1` or a module exporting
  `request_directory_picker/1`) the host installs so the web workspace UI can
  ask the native shell to pick a workspace directory. Desktop never sets it.

  `script_http: :platform_dns_ca` declares that the host configured Req's
  platform DNS and CA certificates before tool registration. It is guidance,
  not a network permission or a promise of connectivity.

  `dns_resolver` optionally supplies a native `fun/1` returning `{:ok, [ip]}`
  or `{:error, reason}` for direct connections. Consumers still validate and
  pin the returned addresses; the callback does not grant network access.

  `git_backend` is an optional module the host installs for Git storage.
  Desktop Mix and Phoenix WebUI leave it unset, so `Handbeam.Git` uses the
  host Git CLI. Phone hosts set it to `Handbeam.Git.ExGit` at boot. Handbeam
  does not infer the backend from the UI, MOB environment variables, or
  missing Git binaries.
  """

  @keys [
    :data_dir,
    :priv_dir,
    :shell,
    :terminal,
    :desktop_browser,
    :webview_browser,
    :system_intents,
    :directory_picker,
    :script_http,
    :dns_resolver,
    :beam_eval,
    :mcp,
    :dist,
    :git_backend
  ]

  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) when key in @keys do
    :handbeam
    |> Application.get_env(:host, %{})
    |> Map.get(key, default)
  end

  @spec put!(map()) :: :ok
  def put!(attrs) when is_map(attrs) do
    Application.put_env(:handbeam, :host, Map.take(attrs, @keys))
  end

  @spec configured?() :: boolean()
  def configured?, do: Application.get_env(:handbeam, :host) != nil

  @spec data_dir() :: String.t()
  def data_dir do
    get(:data_dir) || System.get_env("HOME") || File.cwd!()
  end

  @spec priv_dir() :: String.t()
  def priv_dir do
    get(:priv_dir) || Application.app_dir(:handbeam, "priv")
  end

  @spec shell?() :: boolean()
  def shell?, do: get(:shell, true)

  @spec terminal?() :: boolean()
  def terminal?, do: get(:terminal, true)

  @spec desktop_browser?() :: boolean()
  def desktop_browser?, do: get(:desktop_browser, true)

  @spec webview_browser?() :: boolean()
  def webview_browser? do
    get(:webview_browser, false) == true and not desktop_browser?()
  end

  @doc """
  Host can present system UI for URLs / exported files and run host scripts.

  Gates `android_open_url`, `android_open_file`, `android_share_file` and
  `run_elixir_script`. Not a browser capability; see `webview_browser?/0`.
  """
  @spec system_intents?() :: boolean()
  def system_intents? do
    case get(:system_intents) do
      value when is_boolean(value) -> value
      _ -> webview_browser?()
    end
  end

  @doc """
  Ask the host to open its native directory picker for a new workspace.

  Returns `{:error, :unavailable}` when no host installed a picker.
  """
  @spec request_directory_picker(map()) :: :ok | {:error, term()}
  def request_directory_picker(context \\ %{}) when is_map(context) do
    case get(:directory_picker) do
      fun when is_function(fun, 1) -> fun.(context)
      mod when is_atom(mod) and not is_nil(mod) -> mod.request_directory_picker(context)
      _ -> {:error, :unavailable}
    end
  end

  @spec beam_eval?() :: boolean()
  def beam_eval?, do: get(:beam_eval, false)

  @spec mcp?() :: boolean()
  def mcp?, do: get(:mcp, mix_env() != :test)

  @spec dist?() :: boolean()
  def dist?, do: get(:dist, mix_env() != :prod)

  defp mix_env do
    if function_exported?(Mix, :env, 0), do: Mix.env(), else: :prod
  end
end

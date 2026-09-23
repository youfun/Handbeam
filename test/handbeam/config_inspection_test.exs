defmodule Handbeam.ConfigInspectionTest do
  use ExUnit.Case, async: false

  alias Handbeam.{ConfigInspection, Host, Settings}
  alias Handbeam.Agent.{Config, HostEnvironment}
  alias Handbeam.Tool.Registry

  setup do
    root = Path.join(System.tmp_dir!(), "host-inspection-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".handbeam"))

    keys =
      ~w(HANDBEAM_MODELS_FILE HANDBEAM_GLOBAL_SETTINGS_FILE OPENAI_MODEL OPENAI_BASE_URL PATH)

    env = Map.new(keys, &{&1, System.get_env(&1)})
    app = Application.get_all_env(:handbeam)
    System.put_env("HANDBEAM_MODELS_FILE", Path.join(root, "models.json"))
    System.put_env("HANDBEAM_GLOBAL_SETTINGS_FILE", Path.join(root, "global.json"))
    System.delete_env("OPENAI_MODEL")
    System.delete_env("OPENAI_BASE_URL")
    Host.put!(%{})

    on_exit(fn ->
      Enum.each(env, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      for {key, _} <- Application.get_all_env(:handbeam),
          do: Application.delete_env(:handbeam, key)

      for {key, value} <- app, do: Application.put_env(:handbeam, key, value)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "settings values and winning sources use defaults < global < workspace", %{root: root} do
    write(root, "global.json", %{
      "model_ai" => %{"om_enabled" => true, "om_message_tokens" => 7001}
    })

    write(root, ".handbeam/settings.jsonc", %{
      "model_ai" => %{"om_enabled" => false, "om_message_tokens" => 8003}
    })

    report = ConfigInspection.report(workspace: root)
    # The existing normalizer drops false; inspection must not invent an override.
    assert report.model_ai.om_enabled == %{value: true, source: :global_settings}
    assert report.model_ai.om_message_tokens == %{value: 8003, source: :workspace_settings}
    assert report.model_ai.om_buffer_tokens == %{value: 10_000, source: :model_ai_defaults}
    assert report.model_ai.reasoning == %{value: "medium", source: :model_ai_defaults}
    assert Settings.effective_model_ai(root).om_enabled == true
    assert Settings.effective_model_ai(root).om_message_tokens == 8003
  end

  test "malformed settings and invalid approval mode report fallback without exception data", %{
    root: root
  } do
    write(root, "global.json", %{"model_ai" => "private malformed content"})

    write(root, ".handbeam/settings.jsonc", %{
      "tools" => %{"default_mode" => "private invalid mode"}
    })

    report = ConfigInspection.report(workspace: root)
    assert report.model_ai == %{status: :invalid_settings_shape, effective: :unknown}
    assert report.approval.source == :tool_policy_default
    assert report.approval.effective_default == :auto
    refute Handbeam.JSON.encode!(report) =~ "private"
  end

  test "host overrides, browser precedence and legacy intents fallback are explained", %{
    root: root
  } do
    Host.put!(%{shell: false, desktop_browser: true, webview_browser: true})
    report = ConfigInspection.report(workspace: root)
    assert report.host.shell == %{configured: false, source: :application_host}

    assert report.host.webview_browser == %{
             configured: false,
             source: :desktop_browser_precedence
           }

    assert report.host.system_intents == %{configured: false, source: :webview_browser_fallback}
    assert report.host.terminal.source == :host_default
    assert tool(report, "bash").disabled_reason == :host_capability_disabled
    assert tool(report, "browser").configured
  end

  test "configured tools are neither dependency availability nor actual registration", %{
    root: root
  } do
    # Registration reflects the existing VM, not the Host values changed after startup.
    names = Registry.list()
    Host.put!(%{shell: false, desktop_browser: false, webview_browser: true})
    report = ConfigInspection.report(workspace: root)
    refute tool(report, "bash").configured
    assert tool(report, "bash").registered == "bash" in names
    assert tool(report, "run_elixir_script").configured
    assert tool(report, "run_elixir_script").registered == "run_elixir_script" in names
    assert tool(report, "run_elixir_script").dependency_available == :unknown
    assert tool(report, "run_elixir_script").run_authorized == :unknown
    assert report.model_visibility.status == :unknown
    assert report.execution.shell.executable_found == :not_checked
    assert report.execution.webview.operational == :unknown
    assert report.execution.git.backend == :host_git_cli
    assert report.execution.git.operational == :unknown
    assert report.execution.git.reason == :not_probed
  end

  test "missing executables have a reason without being executed", %{root: root} do
    System.put_env("PATH", root)
    report = ConfigInspection.report(workspace: root)
    refute report.execution.shell.bash_in_path
    assert report.execution.shell.reason == :settings_and_fallback_paths_not_resolved
    assert report.execution.shell.dependency_available == :unknown
    assert report.execution.desktop_browser.reason == :executable_missing
    assert report.execution.shell.operational == :unknown
  end

  test "secrets in arbitrary fields, errors, URLs and paths cannot enter the report", %{
    root: root
  } do
    secret = "private-fixture-value-never-export"
    System.put_env("OPENAI_MODEL", secret)
    System.put_env("OPENAI_BASE_URL", "https://user:#{secret}@example.org")
    Host.put!(%{data_dir: Path.join(root, secret), dns_resolver: fn _ -> raise secret end})

    write(root, "models.json", %{
      "providers" => %{"private" => %{"apiKey" => secret, "Authorization" => secret}}
    })

    write(root, "global.json", %{
      "model_ai" => %{"default_model" => secret, "reasoning" => secret},
      "secret" => secret
    })

    write(root, ".handbeam/settings.jsonc", %{
      "tools" => %{"allow" => [secret], "per_tool" => %{secret => "prompt"}}
    })

    :ok =
      Registry.register_virtual(secret, secret, %{}, fn _, _ ->
        flunk("executed inspection tool")
      end)

    on_exit(fn -> Registry.unregister(secret) end)
    report = ConfigInspection.report(workspace: root)
    refute Handbeam.JSON.encode!(report) =~ secret
    assert report.model_ai.default_model.value == :withheld
    assert report.model_catalog.credentials == :not_resolved
    assert report.model_catalog.runtime_overrides["OPENAI_MODEL"]
    assert report.approval.allow_rules == 1
    File.write!(Path.join(root, ".handbeam/settings.jsonc"), "{\"#{secret}\": broken")
    report = ConfigInspection.report(workspace: root)
    assert report.approval.status == :workspace_settings_error
    refute Handbeam.JSON.encode!(report) =~ secret
  end

  test "inspection leaves runtime configuration, registry and files unchanged", %{root: root} do
    Host.put!(%{directory_picker: fn _ -> flunk("inspection invoked a callback") end, mcp: true})
    write(root, ".handbeam/settings.jsonc", %{"tools" => %{"default_mode" => "deny"}})
    config = Application.get_all_env(:handbeam) |> Enum.sort()
    registry = :sys.get_state(Registry)
    files = files(root)
    report = ConfigInspection.report(workspace: root)
    assert report.approval.effective_default == :deny
    assert report.approval.call_decision == :unknown
    assert report.execution.mcp.reason == :not_probed
    assert Enum.sort(Application.get_all_env(:handbeam)) == config
    assert :sys.get_state(Registry) == registry
    assert files(root) == files
  end

  for platform <- [:android, :ios] do
    @tag platform: platform
    test "#{platform} no-shell host facts reach default and custom model prompts", %{root: root} do
      # Both native entry points install these same Host capabilities. No OS sniffing.
      Host.put!(%{
        shell: false,
        terminal: false,
        desktop_browser: false,
        webview_browser: true,
        system_intents: true
      })

      for extra <- [[], [system_prompt: "Custom instructions."], [system_prompt: nil]] do
        config =
          Config.from_opts(
            [
              working_directory: root,
              provider: Handbeam.TestSupport.FakeProvider,
              provider_config: %{notify: self()},
              middleware: []
            ] ++ extra
          )

        state = Handbeam.Agent.State.init(config, "Check the host facts")
        assert Handbeam.Agent.Turn.run_loop(state, []).status == :completed
        assert_receive {:provider_config, provider_config}
        prompt = provider_config.system_prompt
        assert prompt == config.system_prompt
        assert prompt =~ "There is no Unix shell on this host"
        assert prompt =~ "host WebView session"
        assert prompt =~ "`run_elixir_script`"
        assert prompt =~ "Mix.install/2"
        assert prompt =~ "arbitrary NIFs and external builds are not supported"
        assert prompt =~ "Follow the script tool environment for Mix/Hex availability"
        refute prompt =~ "The `bash` tool runs commands"
        refute prompt =~ "The host permits the bash backend"
        refute prompt =~ "backend is agent-browser CLI"
        assert length(String.split(prompt, "## Host execution environment")) == 2
      end

      assert ConfigInspection.report(workspace: root).prompt.environment_sections ==
               HostEnvironment.sections()
    end
  end

  test "Web does not replace the desktop host or imply Linux; headless disables UI independently",
       %{root: root} do
    Application.put_env(:handbeam, HandbeamWeb.Endpoint, server: true)
    prompt = Config.from_opts(working_directory: root).system_prompt
    assert prompt =~ "The host permits the bash backend"
    assert prompt =~ "backend is agent-browser CLI"
    assert prompt =~ "Web is an entry surface, not a Linux execution host"
    refute prompt =~ "There is no Unix shell"

    Host.put!(%{
      shell: true,
      desktop_browser: false,
      webview_browser: false,
      system_intents: false
    })

    prompt = Config.from_opts(working_directory: root).system_prompt
    assert prompt =~ "Neither desktop nor WebView browser"
    refute prompt =~ "`run_elixir_script`"
    report = ConfigInspection.report(workspace: root)
    assert report.ui.web_server_configured
    assert report.ui.active_surface == :unknown
    assert report.host.shell.configured
    refute tool(report, "browser").configured
  end

  defp tool(report, name), do: Enum.find(report.tools, &(&1.name == name))

  defp write(root, path, value),
    do: File.write!(Path.join(root, path), Handbeam.JSON.encode!(value))

  defp files(root),
    do:
      Map.new(
        Path.wildcard(Path.join(root, "**/*"), match_dot: true) |> Enum.filter(&File.regular?/1),
        &{&1, File.read!(&1)}
      )
end

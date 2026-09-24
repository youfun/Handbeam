defmodule Handbeam.Agent.ConfigTest do
  use ExUnit.Case, async: true

  alias Handbeam.Agent.Config

  describe "provider resolution" do
    test "uses ZenMux adapter when provider field is zenmux" do
      config = Config.from_opts(provider_config: %{provider: "zenmux", api: :openai})

      assert config.provider == Handbeam.Agent.Provider.ZenMux
    end

    test "uses OpenRouter adapter when provider field is openrouter" do
      config = Config.from_opts(provider_config: %{provider: "openrouter", api: :openai})

      assert config.provider == Handbeam.Agent.Provider.OpenRouter
    end

    test "uses DeepSeek adapter when provider field is deepseek" do
      config = Config.from_opts(provider_config: %{provider: "deepseek", api: :openai})

      assert config.provider == Handbeam.Agent.Provider.DeepSeek
    end

    test "uses StepFun adapter when provider field is stepfun" do
      config = Config.from_opts(provider_config: %{provider: "stepfun", api: :openai})

      assert config.provider == Handbeam.Agent.Provider.StepFun
    end

    test "uses Anthropic adapter when StepFun provider declares anthropic messages API" do
      config = Config.from_opts(provider_config: %{provider: "stepfun", api: :anthropic})

      assert config.provider == Handbeam.Agent.Provider.Anthropic
    end

    test "uses StepFun adapter when api field is :stepfun" do
      config = Config.from_opts(provider_config: %{api: :stepfun})

      assert config.provider == Handbeam.Agent.Provider.StepFun
    end

    test "uses OpenAI Responses adapter when provider field is openai" do
      config = Config.from_opts(provider_config: %{provider: "openai", api: :openai_responses})

      assert config.provider == Handbeam.Agent.Provider.OpenAI
    end

    test "uses OpenAI Responses adapter when api field is :openai_responses" do
      config = Config.from_opts(provider_config: %{api: :openai_responses})

      assert config.provider == Handbeam.Agent.Provider.OpenAI
    end

    test "uses Anthropic adapter when api field is :anthropic" do
      config = Config.from_opts(provider_config: %{api: :anthropic})

      assert config.provider == Handbeam.Agent.Provider.Anthropic
    end

    test "openai-compat provider field keeps chat completions routing" do
      config =
        Config.from_opts(provider_config: %{provider: "openai-compat", api: :openai_responses})

      assert config.provider == Handbeam.Agent.Provider.OpenAICompat
    end

    test "uses OpenAI-compatible adapter by default" do
      config = Config.from_opts(provider_config: %{api: :openai})

      assert config.provider == Handbeam.Agent.Provider.OpenAICompat
    end

    test "uses Step Router as the built-in model default" do
      config = Config.from_opts([])

      assert config.model == "step-router-v1"
    end
  end

  test "appends task_instructions after the default prompt and workspace contract" do
    workspace =
      Path.join(System.tmp_dir!(), "handbeam-config-task-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    try do
      config =
        Config.from_opts(
          working_directory: workspace,
          task_instructions: "Write only visible facts."
        )

      assert config.system_prompt =~ "You are Handbeam"
      assert config.system_prompt =~ "Current workspace: #{workspace}"
      assert config.system_prompt =~ "## Task instructions"
      assert config.system_prompt =~ "Write only visible facts."
      refute config.system_prompt =~ "IGNORE ALL PRIOR"
    after
      File.rm_rf(workspace)
    end
  end

  test "blank task_instructions is a no-op" do
    config = Config.from_opts(task_instructions: "   ")
    refute config.system_prompt =~ "## Task instructions"
  end

  test "custom system_prompt still receives task_instructions as an appendix" do
    config =
      Config.from_opts(
        system_prompt: "Custom only.",
        task_instructions: "Keep negatives."
      )

    assert config.system_prompt =~ "Custom only."
    assert config.system_prompt =~ "Keep negatives."
    refute config.system_prompt =~ "Current Workspace"
  end

  describe "workspace prompt contract" do
    test "injects the current workspace as the default command directory" do
      workspace =
        Path.join(
          System.tmp_dir!(),
          "handbeam-config-workspace-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace)

      try do
        config = Config.from_opts(working_directory: workspace)

        assert config.working_directory == workspace
        assert config.system_prompt =~ "Current workspace: #{workspace}"
        assert config.system_prompt =~ "Prefer workspace-relative file paths"
        assert config.system_prompt =~ "workspace root is NOT the filesystem root"
        assert config.system_prompt =~ "runs commands from the current workspace by default"
        assert config.system_prompt =~ "Do not prefix commands with `cd #{workspace} &&`"
        refute config.system_prompt =~ "This session runs on a phone"
      after
        File.rm_rf(workspace)
      end
    end

    test "host without shell injects the no-shell tool contract" do
      previous = Application.get_env(:handbeam, :host)

      Handbeam.Host.put!(%{
        data_dir: "/tmp/mob-data",
        shell: false,
        terminal: false,
        desktop_browser: false,
        webview_browser: true,
        beam_eval: false
      })

      try do
        config = Config.from_opts(working_directory: "/tmp/mob-data/workspace")
        assert config.system_prompt =~ "There is no Unix shell on this host"
        assert config.system_prompt =~ "browser availability is independent of shell access"
        assert config.system_prompt =~ "run_elixir_script"
        assert config.system_prompt =~ "Mix.install/2"

        assert config.system_prompt =~
                 "Follow the script tool environment for Mix/Hex availability"

        refute config.system_prompt =~ "NimbleCSV.RFC4180"
        refute config.system_prompt =~ "Req.get"

        refute config.system_prompt =~ "Do not call `bash` or `browser`"
        refute config.system_prompt =~ "The `bash` tool runs commands"
      after
        if previous,
          do: Application.put_env(:handbeam, :host, previous),
          else: Application.delete_env(:handbeam, :host)
      end
    end

    test "run_elixir_script prompt text follows system_intents?, not webview_browser?" do
      previous = Application.get_env(:handbeam, :host)

      try do
        # Explicit system_intents without any WebView browser still advertises the script tool.
        Handbeam.Host.put!(%{
          shell: false,
          terminal: false,
          desktop_browser: false,
          webview_browser: false,
          system_intents: true
        })

        config = Config.from_opts(working_directory: "/tmp/mob-data/workspace")
        assert config.system_prompt =~ "There is no Unix shell on this host"
        assert config.system_prompt =~ "`run_elixir_script`"
        assert config.system_prompt =~ "high-privilege host BEAM code"

        # A WebView-browser host that opts out of system_intents must not mention it.
        Handbeam.Host.put!(%{
          shell: false,
          terminal: false,
          desktop_browser: false,
          webview_browser: true,
          system_intents: false
        })

        config = Config.from_opts(working_directory: "/tmp/mob-data/workspace")
        assert config.system_prompt =~ "There is no Unix shell on this host"
        refute config.system_prompt =~ "run_elixir_script"
        refute config.system_prompt =~ "already has OTP/Elixir installed"
        refute config.system_prompt =~ "high-privilege host BEAM code"
      after
        if previous,
          do: Application.put_env(:handbeam, :host, previous),
          else: Application.delete_env(:handbeam, :host)
      end
    end
  end
end

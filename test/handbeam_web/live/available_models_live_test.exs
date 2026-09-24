defmodule HandbeamWeb.AvailableModelsLiveTest do
  use HandbeamWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Handbeam.Agent.ModelConfig

  setup do
    home_dir = isolate_sigil_home!()
    write_test_models_config(Path.join(home_dir, ".handbeam/models.json"))
    :ok
  end

  test "llm_db autofills provider and model defaults in add provider form", %{conn: conn} do
    {:ok, view, _html} =
      live_isolated(conn, HandbeamWeb.AvailableModelsLive, session: %{"embedded" => "true"})

    view
    |> element(~s|button[phx-click="open_add_provider"]|)
    |> render_click()

    view
    |> form(~s|form[phx-submit="submit_add_provider"]|, %{
      "add_provider" => %{"id" => "openai", "model_id" => "gpt-4o-mini"}
    })
    |> render_change()

    html = render(view)

    assert html =~ ~s(value="OpenAI")
    assert html =~ ~s(value="https://api.openai.com/v1")
    refute html =~ "env:OPENAI_API_KEY"
    refute html =~ "env:VAR"
    refute html =~ "环境变量"
    refute html =~ "Supports env:VAR"
    assert html =~ ~s(value="GPT-4o mini")
    assert html =~ ~s(value="16384")
    assert html =~ ~s(value="0.15")
    assert html =~ ~s(value="0.6")
  end

  test "submitting a provider stores llm_db-derived price metadata", %{conn: conn} do
    {:ok, view, _html} =
      live_isolated(conn, HandbeamWeb.AvailableModelsLive, session: %{"embedded" => "true"})

    view
    |> element(~s|button[phx-click="open_add_provider"]|)
    |> render_click()

    params = %{
      "add_provider" => %{
        "id" => "anthropic",
        "name" => "Anthropic",
        "api" => "anthropic-messages",
        "base_url" => "https://api.anthropic.com",
        "api_key" => "env:ANTHROPIC_API_KEY",
        "provider_runtime" => "anthropic",
        "model_id" => "claude-sonnet-4-20250514",
        "model_name" => "Claude Sonnet 4",
        "context_window" => "200000",
        "max_tokens" => "64000",
        "price_input" => "3",
        "price_output" => "15",
        "price_cache_read" => "0.3",
        "price_cache_write" => "3.75",
        "price_reasoning" => ""
      }
    }

    render_submit(view, "submit_add_provider", params)

    {:ok, config} =
      ModelConfig.config_file_path()
      |> File.read()
      |> then(fn {:ok, json} -> Jason.decode(json) end)

    provider = get_in(config, ["providers", "anthropic"])
    model = get_in(provider, ["models", Access.at(0)])

    assert provider["provider"] == "anthropic"
    assert provider["api"] == "anthropic-messages"

    assert model["cost"] == %{
             "input" => 3.0,
             "output" => 15.0,
             "cache_read" => 0.3,
             "cache_write" => 3.75
           }

    refute Map.has_key?(model, "reasoning")
  end

  test "adding a model marked as reasoning stores the flag and default level", %{conn: conn} do
    {:ok, view, _html} =
      live_isolated(conn, HandbeamWeb.AvailableModelsLive, session: %{"embedded" => "true"})

    view
    |> element(~s|button[phx-click="select_provider"][phx-value-id="stepfun"]|)
    |> render_click()

    view
    |> element(~s|button[phx-click="open_add_model"]|)
    |> render_click()

    render_submit(view, "submit_add_model", %{
      "add_model" => %{
        "id" => "custom-reasoner",
        "name" => "Custom Reasoner",
        "type" => "text",
        "context_window" => "256000",
        "max_tokens" => "8192",
        "reasoning" => "true"
      }
    })

    {:ok, config} =
      ModelConfig.config_file_path()
      |> File.read!()
      |> Jason.decode()

    model =
      config
      |> get_in(["providers", "stepfun", "models"])
      |> Enum.find(&(&1["id"] == "custom-reasoner"))

    assert model["reasoning"] == true
    assert model["defaultReasoning"] == "medium"
    assert model["thinkingLevelMap"]["high"] == "high"

    html = render(view)
    assert html =~ "custom-reasoner"

    assert Regex.match?(
             ~r/Off\s*\/\s*Minimal\s*\/\s*Low\s*\/\s*Medium\s*\/\s*High\s*\/\s*X-High/,
             html
           )
  end

  test "adding a grok model stores only the selected reasoning levels", %{conn: conn} do
    {:ok, view, _html} =
      live_isolated(conn, HandbeamWeb.AvailableModelsLive, session: %{"embedded" => "true"})

    view
    |> element(~s|button[phx-click="select_provider"][phx-value-id="stepfun"]|)
    |> render_click()

    view
    |> element(~s|button[phx-click="open_add_model"]|)
    |> render_click()

    render_submit(view, "submit_add_model", %{
      "add_model" => %{
        "id" => "grok-4.7",
        "name" => "Grok 4.7",
        "type" => "text",
        "reasoning" => "true",
        "reasoning_levels" => ["", "low", "xhigh"]
      }
    })

    {:ok, config} =
      ModelConfig.config_file_path()
      |> File.read!()
      |> Jason.decode()

    model =
      config
      |> get_in(["providers", "stepfun", "models"])
      |> Enum.find(&(&1["id"] == "grok-4.7"))

    assert model["reasoning"] == true
    assert model["defaultReasoning"] == "low"
    assert model["thinkingLevelMap"]["low"] == "low"
    assert model["thinkingLevelMap"]["medium"] == nil
    assert model["thinkingLevelMap"]["xhigh"] == "high"
    refute Map.has_key?(model["thinkingLevelMap"], "off")

    html = render(view)
    assert Regex.match?(~r/grok-4\.7.*?Low\s*\/\s*X-High/s, html)
    refute Regex.match?(~r/grok-4\.7.*?Off\s*\/\s*Minimal/s, html)
  end

  defmodule MockXaiReq do
    def post(url, opts) do
      replies = :ets.lookup_element(:xai_oauth_live_mock, :replies, 2)
      calls = :ets.lookup_element(:xai_oauth_live_mock, :calls, 2)
      :ets.insert(:xai_oauth_live_mock, {:calls, calls ++ [{url, opts}]})

      case replies do
        [reply | rest] ->
          :ets.insert(:xai_oauth_live_mock, {:replies, rest})
          reply

        [] ->
          flunk("Unexpected xAI OAuth request to #{url}")
      end
    end
  end

  test "xAI subscription login starts the device flow and shows the user code", %{conn: conn} do
    :ets.new(:xai_oauth_live_mock, [:named_table, :public, :set])
    :ets.insert(:xai_oauth_live_mock, {:calls, []})
    Application.put_env(:handbeam, :xai_oauth_req_module, MockXaiReq)

    on_exit(fn ->
      Application.delete_env(:handbeam, :xai_oauth_req_module)

      if :ets.whereis(:xai_oauth_live_mock) != :undefined do
        :ets.delete(:xai_oauth_live_mock)
      end
    end)

    :ets.insert(
      :xai_oauth_live_mock,
      {:replies,
       [
         {:ok,
          %{
            status: 200,
            body: %{
              "device_code" => "device-code",
              "user_code" => "ABCD-1234",
              "verification_uri" => "https://accounts.x.ai/oauth2/device",
              "verification_uri_complete" =>
                "https://accounts.x.ai/oauth2/device?user_code=ABCD-1234",
              "expires_in" => 900,
              "interval" => 5
            }
          }}
       ]}
    )

    {:ok, view, _html} =
      live_isolated(conn, HandbeamWeb.AvailableModelsLive, session: %{"embedded" => "true"})

    html =
      view
      |> element(~s|button[phx-click="open_subscription_login"]|)
      |> render_click()

    assert html =~ "Select provider to configure"
    assert html =~ "xAI (Grok/X subscription)"

    view
    |> element(~s|button[phx-click="start_subscription_oauth"][phx-value-id="xai"]|)
    |> render_click()

    overlay = view |> element(".settings-overlay") |> render()

    assert overlay =~ "ABCD-1234"
    assert overlay =~ "https://accounts.x.ai/oauth2/device?user_code=ABCD-1234"
    assert overlay =~ "xAI (Grok/X subscription)"
    assert overlay =~ "Waiting for authentication..."

    {:ok, config} =
      ModelConfig.config_file_path()
      |> File.read!()
      |> Jason.decode()

    provider = get_in(config, ["providers", "xai"])
    assert provider["authType"] == "oauth"
    assert provider["api"] == "openai-responses"
    assert Enum.any?(provider["models"], &(&1["id"] == "grok-4.7"))
  end

  test "Cursor subscription login shows the browser authorization URL", %{conn: conn} do
    {:ok, view, html} =
      live_isolated(conn, HandbeamWeb.AvailableModelsLive, session: %{"embedded" => "true"})

    assert html =~ "Subscription Sign-in" or html =~ "订阅登录"

    html =
      view
      |> element(~s|button[phx-click="open_subscription_login"]|)
      |> render_click()

    assert html =~ "Cursor (account subscription)"

    view
    |> element(~s|button[phx-click="start_subscription_oauth"][phx-value-id="cursor"]|)
    |> render_click()

    overlay = view |> element(".settings-overlay") |> render()
    assert overlay =~ "https://cursor.com/loginDeepControl"
    assert overlay =~ "Waiting for authentication..."
    assert overlay =~ "非官方协议"
    refute overlay =~ "user_code"

    {:ok, config} =
      ModelConfig.config_file_path()
      |> File.read!()
      |> Jason.decode()

    provider = get_in(config, ["providers", "cursor"])
    assert provider["authType"] == "oauth"
    assert provider["api"] == "cursor-agent"
    assert provider["models"] == []
  end

  test "cancelled Cursor discovery does not apply a late result", %{conn: conn} do
    {:ok, view, _html} =
      live_isolated(conn, HandbeamWeb.AvailableModelsLive, session: %{"embedded" => "true"})

    view
    |> element(~s|button[phx-click="open_subscription_login"]|)
    |> render_click()

    view
    |> element(~s|button[phx-click="start_subscription_oauth"][phx-value-id="cursor"]|)
    |> render_click()

    send(view.pid, {:cursor_models_discovered, 999, {:ok, [%{"id" => "late", "name" => "Late"}]}})
    html = render(view)
    refute html =~ "Late"
  end

  test "cancelling Cursor login hides the overlay", %{conn: conn} do
    {:ok, view, _html} =
      live_isolated(conn, HandbeamWeb.AvailableModelsLive, session: %{"embedded" => "true"})

    view
    |> element(~s|button[phx-click="open_subscription_login"]|)
    |> render_click()

    view
    |> element(~s|button[phx-click="start_subscription_oauth"][phx-value-id="cursor"]|)
    |> render_click()

    html =
      view
      |> element(~s|button[phx-click="cancel_subscription_oauth"]|)
      |> render_click()

    refute html =~ "https://cursor.com/loginDeepControl"
  end

  test "editing provider preserves api type when submit params are partial", %{conn: conn} do
    {:ok, view, _html} =
      live_isolated(conn, HandbeamWeb.AvailableModelsLive, session: %{"embedded" => "true"})

    view
    |> element(~s|button[phx-click="select_provider"][phx-value-id="stepfun"]|)
    |> render_click()

    view
    |> element(~s|button[phx-click="open_edit_provider"][phx-value-id="stepfun"]|)
    |> render_click()

    html = render(view)
    assert html =~ ~s(phx-click-away="close_edit_provider")
    refute html =~ ~s(phx-click="noop")
    refute html =~ "env:OPENAI_API_KEY"
    refute html =~ "env:VAR"

    render_submit(view, "submit_edit_provider", %{
      "edit_provider" => %{"name" => "StepFun Updated"}
    })

    {:ok, config} =
      ModelConfig.config_file_path()
      |> File.read()
      |> then(fn {:ok, json} -> Jason.decode(json) end)

    provider = get_in(config, ["providers", "stepfun"])
    assert provider["name"] == "StepFun Updated"
    assert provider["api"] == "stepfun-step-plan"
    assert provider["baseUrl"] == "https://api.stepfun.com/step_plan/v1"
    assert provider["apiKey"] == "env:OPENAI_API_KEY"
  end

  test "model toggle hides a model from the picker and keeps the row", %{conn: conn} do
    {:ok, view, _html} =
      live_isolated(conn, HandbeamWeb.AvailableModelsLive, session: %{"embedded" => "true"})

    view
    |> element(~s|button[phx-click="select_provider"][phx-value-id="stepfun"]|)
    |> render_click()

    view
    |> element(~s|input[phx-click="toggle_model_enabled"][phx-value-id="step-router-v1"]|)
    |> render_click()

    html = render(view)
    assert html =~ "step-router-v1"
    assert html =~ "is-disabled"

    {:ok, stored} = ModelConfig.config_file_path() |> File.read!() |> Jason.decode()
    model = get_in(stored, ["providers", "stepfun", "models", Access.at(0)])
    assert model["enabled"] == false

    view
    |> element(~s|input[phx-click="toggle_model_enabled"][phx-value-id="step-router-v1"]|)
    |> render_click()

    {:ok, stored} = ModelConfig.config_file_path() |> File.read!() |> Jason.decode()
    model = get_in(stored, ["providers", "stepfun", "models", Access.at(0)])
    assert model["enabled"] == true
  end

  test "cursor rows show the upstream vendor price without a refresh", %{conn: conn} do
    path = ModelConfig.config_file_path()

    File.write!(
      path,
      Jason.encode!(%{
        "defaultProvider" => "cursor",
        "providers" => %{
          "cursor" => %{
            "name" => "Cursor",
            "api" => "cursor-agent",
            "models" => [
              %{
                "id" => "gpt-5.3-codex-low-fast",
                "name" => "Codex 5.3 Low Fast",
                "input" => ["text"]
              },
              %{"id" => "claude-opus-4.6", "name" => "Claude Opus 4.6", "input" => ["text"]},
              %{"id" => "composer-2.5", "name" => "Composer 2.5", "input" => ["text"]}
            ]
          }
        }
      })
    )

    {:ok, view, _html} =
      live_isolated(conn, HandbeamWeb.AvailableModelsLive, session: %{"embedded" => "true"})

    view
    |> element(~s|button[phx-click="select_provider"][phx-value-id="cursor"]|)
    |> render_click()

    html = render(view)
    assert html =~ "in 1.75 / out 14"
    assert html =~ "in 5 / out 25"
    assert html =~ "composer-2.5"
  end

  defp isolate_sigil_home! do
    old_home = System.get_env("HOME")

    home_dir =
      Path.join(
        System.tmp_dir!(),
        "sigil_available_models_home_#{System.unique_integer([:positive])}"
      )

    System.put_env("HOME", home_dir)

    models_path = Path.join(home_dir, ".handbeam/models.json")
    System.put_env("HANDBEAM_MODELS_FILE", models_path)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      System.delete_env("HANDBEAM_MODELS_FILE")
      if File.exists?(home_dir), do: File.rm_rf!(home_dir)
    end)

    home_dir
  end

  defp write_test_models_config(path) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "defaultProvider" => "stepfun",
        "defaultModel" => "step-router-v1",
        "providers" => %{
          "stepfun" => %{
            "name" => "StepFun",
            "baseUrl" => "https://api.stepfun.com/step_plan/v1",
            "api" => "stepfun-step-plan",
            "provider" => "stepfun",
            "apiKey" => "env:OPENAI_API_KEY",
            "models" => [
              %{
                "id" => "step-router-v1",
                "name" => "Step Router v1",
                "input" => ["text"],
                "contextWindow" => 256_000
              }
            ]
          }
        }
      })
    )
  end
end

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

    {:ok, config} =
      ModelConfig.config_file_path()
      |> File.read!()
      |> Jason.decode()

    provider = get_in(config, ["providers", "xai"])
    assert provider["authType"] == "oauth"
    assert provider["api"] == "openai-responses"
    assert Enum.any?(provider["models"], &(&1["id"] == "grok-4.6"))
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

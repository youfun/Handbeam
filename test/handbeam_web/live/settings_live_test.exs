defmodule HandbeamWeb.SettingsLiveTest do
  @moduledoc """
  Tests for the unified Settings page (SettingsLive).

  Covers:
    - Mount renders settings page with left menu
    - Default tab is Model / AI with form
    - Tab switching works via menu clicks
    - Available Models tab renders nested AvailableModelsLive (text presence,
      interaction tests are in a separate AvailableModelsLive test)
    - Coming-soon tabs show placeholder
    - URL query param sets initial tab
    - Top bar has back-to-workspace link
  """

  use HandbeamWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    home_dir = isolate_sigil_home!()
    write_test_models_config(Path.join(home_dir, ".handbeam/models.json"))
    :ok
  end

  # ── Helpers ──

  defp isolate_sigil_home! do
    old_home = System.get_env("HOME")

    home_dir =
      Path.join(System.tmp_dir!(), "sigil_settings_home_#{System.unique_integer([:positive])}")

    System.put_env("HOME", home_dir)

    models_path = Path.join(home_dir, ".handbeam/models.json")
    workspaces_path = Path.join(home_dir, ".handbeam/workspaces.json")
    workspace_path = Path.join(home_dir, ".handbeam/workspace")
    System.put_env("HANDBEAM_MODELS_FILE", models_path)
    System.put_env("HANDBEAM_WORKSPACES_FILE", workspaces_path)
    System.put_env("HANDBEAM_WORKSPACE", workspace_path)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      System.delete_env("HANDBEAM_MODELS_FILE")
      System.delete_env("HANDBEAM_WORKSPACES_FILE")
      System.delete_env("HANDBEAM_WORKSPACE")
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
                "reasoning" => true,
                "defaultReasoning" => "medium",
                "contextWindow" => 256_000,
                "input" => ["text"]
              },
              %{
                "id" => "step-3.5-flash",
                "name" => "Step 3.5 Flash",
                "input" => ["text"],
                "contextWindow" => 128_000
              }
            ]
          },
          "openai" => %{
            "name" => "OpenAI",
            "baseUrl" => "https://api.openai.com/v1",
            "api" => "openai",
            "provider" => "openai",
            "apiKey" => "env:OPENAI_API_KEY",
            "models" => [
              %{
                "id" => "gpt-4o",
                "name" => "GPT-4o",
                "input" => ["text", "image"],
                "contextWindow" => 128_000
              }
            ]
          }
        }
      })
    )
  end

  # ── Tests ──

  describe "GET /settings" do
    test "renders settings page with left menu", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Settings"
      assert html =~ "Model / AI"
      assert html =~ "Workspace Models"
      assert html =~ "Available Models"
      assert html =~ "UI"
      assert html =~ "Coming soon" or html =~ "即将推出"
    end

    test "has back-to-workspace link", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Back to Workspace"
    end

    test "defaults to Model / AI tab showing the form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      # Form with model selection and reasoning is rendered
      assert html =~ ~s(name="default_model")
      assert html =~ ~s(name="reasoning")
    end

    test "first visit seeds default models into the Model / AI picker", %{conn: conn} do
      models_path = System.fetch_env!("HANDBEAM_MODELS_FILE")
      File.rm(models_path)
      refute File.exists?(models_path)

      {:ok, _view, html} = live(conn, "/settings?tab=model_ai")

      assert File.exists?(models_path)
      assert html =~ ~s(name="default_model")
      assert html =~ "Step Router v1"
    end

    test "Model / AI model lists use global models even when workspace policy is restricted",
         %{conn: conn} do
      {:ok, default_workspace} = Handbeam.WorkspaceStore.ensure_default!()

      settings_path = Handbeam.WorkspaceSettings.path(default_workspace["path"])
      File.mkdir_p!(Path.dirname(settings_path))

      File.write!(
        settings_path,
        Jason.encode!(%{
          "models" => %{
            "allow" => %{
              "providers" => %{
                "stepfun" => %{"models" => ["step-router-v1"]}
              }
            }
          }
        })
      )

      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "stepfun / Step Router v1"
      assert html =~ "stepfun / Step 3.5 Flash"
    end

    test "can switch to Available Models tab and see provider list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element(~s|button[phx-value-tab="available_models"]|)
      |> render_click()

      html = render(view)

      # Nested AvailableModelsLive renders provider list from models.json
      assert html =~ "Providers"
      assert html =~ "StepFun"
      assert html =~ "OpenAI"
    end

    test "Workspace Models tab edits current workspace policy", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element(~s|button[phx-value-tab="workspace_models"]|)
      |> render_click()

      html = render(view)
      assert html =~ "Current workspace models"
      assert html =~ "Unrestricted"

      view
      |> element(~s|button[phx-click="set_workspace_model_mode"][phx-value-mode="restricted"]|)
      |> render_click()

      html = render(view)
      assert html =~ "Step Router v1"
      assert html =~ "Step 3.5 Flash"

      view
      |> element(~s|input[phx-click="toggle_workspace_model"][phx-value-model="step-router-v1"]|)
      |> render_click()

      render_change(view, "set_workspace_default_model", %{
        "default_model" => "stepfun/step-router-v1"
      })

      view
      |> element(~s|button[phx-click="save_workspace_models"]|)
      |> render_click()

      default_workspace =
        Handbeam.WorkspaceStore.list()
        |> Enum.find(&(&1["default"] || &1["id"] == "default"))

      workspace_settings_path = Handbeam.WorkspaceSettings.path(default_workspace["path"])

      {:ok, settings} =
        workspace_settings_path
        |> File.read!()
        |> Jason.decode()

      assert get_in(settings, ["models", "default"]) == %{
               "provider" => "stepfun",
               "model" => "step-router-v1"
             }

      assert get_in(settings, ["models", "allow", "providers", "stepfun", "models"]) == [
               "step-router-v1"
             ]
    end

    test "Available Models tab shows default provider badge", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element(~s|button[phx-value-tab="available_models"]|)
      |> render_click()

      html = render(view)

      assert html =~ "Default"
    end

    test "switching back to Model / AI tab shows form again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element(~s|button[phx-value-tab="available_models"]|)
      |> render_click()

      view
      |> element(~s|button[phx-value-tab="model_ai"]|)
      |> render_click()

      html = render(view)

      assert html =~ ~s(name="default_model")
    end

    test "coming-soon tabs show placeholder text", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element(~s|button[phx-value-tab="coming_soon"]|)
      |> render_click()

      html = render(view)

      assert html =~ "coming soon"
      assert html =~ "SNS"
      assert html =~ "Tools"
      assert html =~ "Security"
    end

    test "uses URL query param to set initial tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings?tab=available_models")

      assert html =~ "Available Models"
    end

    test "loads specific workspace based on query param", %{conn: conn} do
      # Create a new non-default workspace
      tmp_ws_dir =
        Path.join(System.tmp_dir!(), "handbeam_test_ws_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_ws_dir)

      {:ok, ws} = Handbeam.WorkspaceStore.add(tmp_ws_dir, name: "Custom Project")

      # Access settings with workspace_id and workspace_models tab
      {:ok, view, _html} = live(conn, "/settings?tab=workspace_models&workspace_id=#{ws["id"]}")
      html = render(view)
      assert html =~ "Custom Project"
      assert html =~ tmp_ws_dir

      # Clean up
      File.rm_rf!(tmp_ws_dir)
    end

    test "back link uses conversation_id and workspace_id if provided", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings?workspace_id=default&conversation_id=conv_123")
      assert html =~ ~s(href="/w/default/c/conv_123")
    end

    test "select_tab preserves workspace_id and conversation_id in the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings?workspace_id=default&conversation_id=conv_123")

      view
      |> element(~s|button[phx-value-tab="workspace_models"]|)
      |> render_click()

      # We can check that the back link still has the correct href after patch
      html = render(view)
      assert html =~ ~s(href="/w/default/c/conv_123")
    end
  end
end

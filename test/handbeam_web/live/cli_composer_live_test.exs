defmodule HandbeamWeb.CliComposerLiveTest do
  @moduledoc """
  Composer loop-owner choice.

  No CLI selected keeps Handbeam's model list and Provider path. Selecting a
  registered CLI swaps that list for the CLI's own models and sends through
  `Handbeam.Agent.CliAgent.Run`.
  """

  use HandbeamWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Handbeam.Agent.CliAgent.Registry
  alias Handbeam.TestSupport.E2EHarness

  setup do
    E2EHarness.isolate_home!("cli-composer")
    E2EHarness.use_fake_provider!(:simple_answer)
    Registry.reset()
    Application.delete_env(:handbeam, :fake_cli_notify)

    on_exit(fn ->
      for conversation <- Handbeam.ConversationStore.list(include_timeline?: false) do
        E2EHarness.cancel!(conversation["id"])
      end

      Registry.reset()
      Application.delete_env(:handbeam, :fake_cli_notify)
    end)

    :ok
  end

  test "default send keeps the Handbeam model picker and does not call a CLI", %{conn: conn} do
    Registry.register(Handbeam.Agent.CliAgentTest.FakeBackend)
    {:ok, view, html} = live(conn, "/")

    assert html =~ ~s(id="cli-picker")
    assert html =~ "Handbeam"
    assert html =~ ~s(id="model-picker")
    assert has_element?(view, "#model-picker option[value='fake/fake-model']")
    refute has_element?(view, "#cli-model-picker")

    view
    |> form("#composer", %{message: "hello handbeam"})
    |> render_submit()

    refute_received {:fake_cli_turn, _, _}
    assert render(view) =~ "hello handbeam"
    assert has_element?(view, "#model-picker")
    refute has_element?(view, "#cli-model-picker")
  end

  test "selecting a CLI swaps the model list and send uses the CLI run path", %{conn: conn} do
    Registry.register(Handbeam.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbeam, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")

    html =
      view
      |> element("#cli-picker")
      |> render_change(%{"cli" => "fake-cli"})

    assert html =~ "fake-model"
    assert html =~ "Fake"
    refute html =~ ~s(id="cli-models-error")

    view
    |> form("#composer", %{message: "hello cli", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_turn, "hello cli", session}
    assert session.backend == "fake-cli"
    assert render(view) =~ "fake"
  end

  test "a second message reuses the CLI session and switching does not", %{conn: conn} do
    Registry.register(Handbeam.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbeam, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")

    view |> element("#cli-picker") |> render_change(%{"cli" => "fake-cli"})

    view
    |> form("#composer", %{message: "first", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_turn, "first", first}
    assert first.session_id == "fake-new"
    assert first.private.resumed == nil

    view
    |> form("#composer", %{message: "second", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_turn, "second", second}
    assert second.session_id == "fake-new"
    assert second.private.resumed == "fake-new"

    view |> element("#cli-picker") |> render_change(%{"cli" => ""})
    view |> element("#cli-picker") |> render_change(%{"cli" => "fake-cli"})

    view
    |> form("#composer", %{message: "fresh", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_turn, "fresh", fresh}
    assert fresh.private.resumed == nil
  end

  test "a CLI permission renders as a pending approval and only an offered option resumes", %{
    conn: conn
  } do
    Registry.register(Handbeam.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbeam, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")
    view |> element("#cli-picker") |> render_change(%{"cli" => "fake-cli"})

    view
    |> form("#composer", %{message: "need-permission", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_turn, "need-permission", _}
    html = render(view)
    assert html =~ "tool-approval-overlay"
    assert html =~ "CLI approval required"
    assert html =~ "Edit"
    assert has_element?(view, "#cli-approval-proceed_once")

    view |> element("button[phx-click=deny_all_tools]") |> render_click()

    refute_received {:fake_cli_turn, "need-permission", %{private: %{decision: _}}}
    assert render(view) =~ "CLI turn stopped"
    refute has_element?(view, "#tool-approval-overlay")
  end

  test "choosing an offered CLI option resumes that session", %{conn: conn} do
    Registry.register(Handbeam.Agent.CliAgentTest.FakeBackend)
    Application.put_env(:handbeam, :fake_cli_notify, self())
    {:ok, view, _html} = live(conn, "/")
    view |> element("#cli-picker") |> render_change(%{"cli" => "fake-cli"})

    view
    |> form("#composer", %{message: "need-permission", cli: "fake-cli", model: "fake-model"})
    |> render_submit()

    assert_receive {:fake_cli_turn, "need-permission", asked}
    assert has_element?(view, "#cli-approval-proceed_once")

    view |> element("#cli-approval-proceed_once") |> render_click()

    assert_receive {:fake_cli_turn, "need-permission", resumed}
    assert resumed.session_id == asked.session_id
    assert resumed.private.decision == {:permission, "proceed_once"}
    assert render(view) =~ "fake"
    refute has_element?(view, "#tool-approval-overlay")
  end

  test "a CLI that cannot list models does not fall back to the Handbeam catalog", %{conn: conn} do
    Registry.register(HandbeamWeb.CliComposerLiveTest.UnavailableModels)
    {:ok, view, _html} = live(conn, "/")

    html =
      view
      |> element("#cli-picker")
      |> render_change(%{"cli" => "silent-cli"})

    assert html =~ "This CLI cannot list models."
    refute html =~ "fake-model"
    assert has_element?(view, "#cli-models-error")
  end
end

defmodule HandbeamWeb.CliComposerLiveTest.UnavailableModels do
  @moduledoc false
  @behaviour Handbeam.Agent.CliAgent

  alias Handbeam.Agent.CliAgent.Session

  @impl true
  def id, do: "silent-cli"
  @impl true
  def available?, do: true
  @impl true
  def list_models(_opts), do: {:error, :models_unavailable}

  @impl true
  def start_session(opts) do
    {:ok, %Session{backend: id(), cwd: Keyword.get(opts, :cwd, ".")}}
  end

  @impl true
  def send_message(session, _text, on_event) do
    on_event.({:text_delta, "no"})
    {:ok, session, []}
  end

  @impl true
  def interrupt(_session), do: :ok
  @impl true
  def update_model(session, _opts), do: {:ok, session}
  @impl true
  def stop_session(_session), do: :ok
end

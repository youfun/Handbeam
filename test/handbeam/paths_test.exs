defmodule Handbeam.PathsTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:handbeam, :host)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbeam, :host, previous),
        else: Application.delete_env(:handbeam, :host)
    end)

    :ok
  end

  test "priv_dir uses Application.app_dir off device" do
    Application.delete_env(:handbeam, :host)
    assert Handbeam.Paths.priv_dir() == Application.app_dir(:handbeam, "priv")

    assert Handbeam.Paths.static_root() ==
             Path.join(Application.app_dir(:handbeam, "priv"), "static")
  end

  test "priv_dir uses Host.priv_dir when configured" do
    Handbeam.Host.put!(%{priv_dir: "/tmp/mob-beams/priv"})
    assert Handbeam.Paths.priv_dir() == "/tmp/mob-beams/priv"
    assert Handbeam.Paths.migrations_dir() == "/tmp/mob-beams/priv/repo/migrations"
  end

  test "Home.expand maps ~/.handbeam onto Host.data_dir" do
    Handbeam.Host.put!(%{data_dir: "/tmp/mob-data"})

    assert Handbeam.Home.expand("~/.handbeam/models.json") ==
             "/tmp/mob-data/.handbeam/models.json"
  end

  test "phone host tools drop bash and keep grep" do
    Handbeam.Host.put!(%{
      data_dir: "/tmp/mob-data",
      priv_dir: "/tmp/mob-beams/priv",
      shell: false,
      terminal: false,
      browser_backend: :webview,
      artifact_delivery_backend: Handbeam.ArtifactDelivery,
      host_script: true,
      beam_eval: false,
      mcp: false
    })

    names = Enum.map(Handbeam.Agent.default_tools(), & &1.name())
    refute "bash" in names
    assert "browser" in names
    assert "preview_serve" in names
    assert "open_url" in names
    assert "open_file" in names
    assert "share_file" in names
    assert "run_elixir_script" in names
    assert "read" in names
    assert "grep" in names
    assert "code_search" in names
    refute "ext__beam__eval" in names
    refute "ext__beam__sql" in names
  end

  test "session events observations and auth resolve under Host.data_dir" do
    Handbeam.Host.put!(%{data_dir: "/tmp/mob-data"})

    assert Handbeam.SessionStore.File.session_path("s1") ==
             "/tmp/mob-data/.handbeam/sessions/s1.json"

    assert Handbeam.EventRecorder.event_path("s1") ==
             "/tmp/mob-data/.handbeam/events/s1.jsonl"

    assert Handbeam.Memory.ObservationStore.base_dir() ==
             "/tmp/mob-data/.handbeam/observations"

    assert Handbeam.Agent.Auth.Storage.file_path() ==
             "/tmp/mob-data/.handbeam/auth.json"
  end
end

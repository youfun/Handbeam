defmodule Handbeam.HostTest.CLI do
end

defmodule Handbeam.HostTest do
  use ExUnit.Case, async: false

  alias Handbeam.Host

  setup do
    previous = Application.get_env(:handbeam, :host)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbeam, :host, previous),
        else: Application.delete_env(:handbeam, :host)
    end)

    :ok
  end

  test "desktop defaults keep shell and drop eval" do
    Application.delete_env(:handbeam, :host)
    assert Host.shell?()
    assert Host.terminal?()
    assert Host.desktop_browser?()
    refute Host.webview_browser?()
    refute Host.beam_eval?()
    refute Host.configured?()
    assert Host.get(:git_backend) == nil
    assert Handbeam.Git.backend() == Handbeam.Git.CLI
    assert Handbeam.Git.backend_kind() == :host_git_cli
  end

  test "phone host disables shell and desktop browser" do
    Host.put!(%{
      data_dir: "/tmp/mob-data",
      priv_dir: "/tmp/mob-beams/priv",
      shell: false,
      terminal: false,
      desktop_browser: false,
      webview_browser: true,
      beam_eval: false,
      mcp: false,
      dist: true
    })

    assert Host.configured?()
    refute Host.shell?()
    refute Host.terminal?()
    refute Host.desktop_browser?()
    assert Host.webview_browser?()
    refute Host.beam_eval?()
    refute Host.mcp?()
    assert Host.dist?()
    assert Host.data_dir() == "/tmp/mob-data"
    assert Host.priv_dir() == "/tmp/mob-beams/priv"
    assert Host.get(:git_backend) == nil
  end

  test "backend_kind uses module identity rather than a .CLI name suffix" do
    Host.put!(%{git_backend: Handbeam.HostTest.CLI})
    assert Handbeam.Git.backend() == Handbeam.HostTest.CLI
    assert Handbeam.Git.backend_kind() == :injected

    Host.put!(%{git_backend: Handbeam.Git.CLI})
    assert Handbeam.Git.backend_kind() == :host_git_cli
  end

  test "explicit git_backend is returned as-is and is not inferred from shell" do
    Host.put!(%{shell: false, git_backend: Handbeam.Git.CLI})
    assert Host.get(:git_backend) == Handbeam.Git.CLI
    assert Handbeam.Git.backend() == Handbeam.Git.CLI

    Host.put!(%{shell: false, webview_browser: true, desktop_browser: false})
    assert Host.get(:git_backend) == nil
    assert Handbeam.Git.backend() == Handbeam.Git.CLI
  end

  test "webview_browser is ignored when desktop_browser is true" do
    Host.put!(%{desktop_browser: true, webview_browser: true})
    assert Host.desktop_browser?()
    refute Host.webview_browser?()
  end

  describe "system_intents?/0" do
    test "desktop default is false" do
      Application.delete_env(:handbeam, :host)
      refute Host.system_intents?()
    end

    test "falls back to webview_browser? when not declared" do
      Host.put!(%{desktop_browser: false, webview_browser: true})
      assert Host.system_intents?()

      Host.put!(%{desktop_browser: true, webview_browser: true})
      refute Host.system_intents?()
    end

    test "explicit value wins over webview_browser?" do
      Host.put!(%{desktop_browser: false, webview_browser: true, system_intents: false})
      refute Host.system_intents?()

      Host.put!(%{desktop_browser: true, webview_browser: false, system_intents: true})
      assert Host.system_intents?()
    end
  end

  describe "request_directory_picker/1" do
    test "is unavailable when no host installed a picker" do
      Application.delete_env(:handbeam, :host)
      assert Host.request_directory_picker(%{purpose: :add_workspace}) == {:error, :unavailable}

      Host.put!(%{shell: false})
      assert Host.request_directory_picker() == {:error, :unavailable}
    end

    test "calls a fun/1 picker with the context" do
      parent = self()
      Host.put!(%{directory_picker: fn ctx -> send(parent, {:picked, ctx}) end})

      assert Host.request_directory_picker(%{purpose: :add_workspace})
      assert_received {:picked, %{purpose: :add_workspace}}
    end

    test "calls a module picker" do
      defmodule PickerStub do
        def request_directory_picker(ctx), do: {:ok, ctx}
      end

      Host.put!(%{directory_picker: PickerStub})
      assert Host.request_directory_picker(%{purpose: :test}) == {:ok, %{purpose: :test}}
    end
  end
end

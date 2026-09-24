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
    assert Host.browser_backend() == :cli
    assert Host.artifact_delivery_backend() == nil
    refute Host.host_script?()
    refute Host.beam_eval?()
    refute Host.configured?()
    refute Host.packaged_mix_toolchain?()
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
      browser_backend: :webview,
      beam_eval: false,
      mcp: false,
      dist: true,
      packaged_mix_toolchain: true
    })

    assert Host.configured?()
    refute Host.shell?()
    refute Host.terminal?()
    assert Host.browser_backend() == :webview
    assert Host.artifact_delivery_backend() == nil
    refute Host.host_script?()
    refute Host.beam_eval?()
    refute Host.mcp?()
    assert Host.dist?()
    assert Host.packaged_mix_toolchain?()
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

    Host.put!(%{shell: false, browser_backend: :webview})
    assert Host.get(:git_backend) == nil
    assert Handbeam.Git.backend() == Handbeam.Git.CLI
  end

  test "an explicit browser backend is not inferred from another capability" do
    Host.put!(%{browser_backend: :webview, artifact_delivery_backend: nil, host_script: false})
    assert Host.browser_backend() == :webview
    assert Host.artifact_delivery_backend() == nil
    refute Host.host_script?()

    Host.put!(%{browser_backend: nil, shell: false})
    assert Host.browser_backend() == nil
  end

  test "unknown host keys and unrelated booleans are not inferred as backends" do
    Host.put!(%{
      desktop_browser: false,
      webview_browser: true,
      system_intents: true,
      host_script_backend: :ignored
    })

    assert Host.browser_backend() == :cli
    assert Host.artifact_delivery_backend() == nil
    refute Host.host_script?()
    refute Map.has_key?(Application.get_env(:handbeam, :host), :system_intents)
    refute Map.has_key?(Application.get_env(:handbeam, :host), :webview_browser)
    refute Map.has_key?(Application.get_env(:handbeam, :host), :host_script_backend)
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

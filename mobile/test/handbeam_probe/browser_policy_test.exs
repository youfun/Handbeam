defmodule HandbeamProbe.BrowserPolicyTest do
  use ExUnit.Case, async: false

  alias Handbeam.Permissions.ToolPolicy
  alias Handbeam.Tool.Registry

  setup do
    previous = Application.get_env(:handbeam, :host)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbeam, :host, previous),
        else: Application.delete_env(:handbeam, :host)
    end)

    Handbeam.Host.put!(%{
      shell: false,
      terminal: false,
      desktop_browser: false,
      webview_browser: true,
      beam_eval: false,
      mcp: false
    })

    :ok
  end

  test "foundationtest-style default workspace allows native browser open" do
    policy = ToolPolicy.from_settings(%{})

    assert policy.default_mode == :auto
    assert policy.deny == []
    assert policy.per_tool == %{}
    assert Handbeam.Host.webview_browser?()

    assert ToolPolicy.decision(policy, %{
             name: "browser",
             input: %{"action" => "open", "url" => "https://example.org"}
           }) == :auto

    assert ToolPolicy.decision(policy, %{
             name: "browser",
             input: %{"action" => "snapshot"}
           }) == :auto
  end

  test "phone host modules include browser and preview_serve as Registry.get tuples" do
    names = Enum.map(Handbeam.Agent.default_tools(), & &1.name())
    assert "browser" in names
    assert "preview_serve" in names
    assert "run_elixir_script" in names

    Enum.each(Registry.host_tool_modules(), &Registry.register/1)
    assert {:ok, browser} = Registry.get("browser")
    assert {:ok, preview} = Registry.get("preview_serve")
    assert browser.module == Handbeam.Tool.Builtin.Browser
    assert preview.module == Handbeam.Tool.Builtin.PreviewServe
  end
end

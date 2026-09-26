defmodule HandbeamProbe.BrowserPolicyTest do
  use ExUnit.Case, async: false

  alias Handbeam.Permissions.ToolPolicy
  alias Handbeam.Tool.Registry

  setup do
    previous = Application.get_env(:handbeam, :host)
    fixed = :persistent_term.get({Handbeam.Tool.Builtin.Browser, :backend}, :unfixed)
    :ok = Handbeam.Tool.Builtin.Browser.release_backend!()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbeam, :host, previous),
        else: Application.delete_env(:handbeam, :host)

      restore_browser(fixed)
    end)

    Handbeam.Host.put!(%{
      shell: false,
      terminal: false,
      browser_backend: :webview,
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
    assert Handbeam.Host.browser_backend() == :webview

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
    refute "run_elixir_script" in names

    Enum.each(Registry.host_tool_modules(), &Registry.register/1)
    assert {:ok, browser} = Registry.get("browser")
    assert {:ok, preview} = Registry.get("preview_serve")
    assert browser.module == Handbeam.Tool.Builtin.Browser
    assert preview.module == Handbeam.Tool.Builtin.PreviewServe
  end

  defp restore_browser(:unfixed), do: Handbeam.Tool.Builtin.Browser.release_backend!()

  defp restore_browser(backend) do
    :persistent_term.put({Handbeam.Tool.Builtin.Browser, :backend}, backend)
    :ok
  end
end

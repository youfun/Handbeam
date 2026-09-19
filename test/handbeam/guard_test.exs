defmodule Handbeam.GuardTest do
  @moduledoc """
  Guards against merge regressions in host-capability tool seeding
  (tech-debt plan WP1, tightened by WP10).

  WP10 collapsed the two hand-maintained seed lists into one:
  `Handbeam.Tool.Registry.host_tool_modules/0` owns the list and
  `Handbeam.Agent.default_tools/0` delegates to it. These tests fail if a merge
  reintroduces a second copy that drifts, or re-gates the Android intent
  tools on `webview_browser?` instead of `system_intents?`.
  """

  use ExUnit.Case, async: false

  alias Handbeam.Agent
  alias Handbeam.Tool.Registry

  @android_tools MapSet.new(~w(android_open_url android_open_file android_share_file))

  setup do
    previous = Application.get_env(:handbeam, :host)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:handbeam, :host, previous),
        else: Application.delete_env(:handbeam, :host)
    end)

    :ok
  end

  test "Agent.default_tools/0 is the same list as Registry.host_tool_modules/0" do
    for host <- [
          nil,
          %{shell: false, desktop_browser: false, webview_browser: true, beam_eval: false},
          %{shell: false, desktop_browser: false, webview_browser: false, system_intents: true},
          %{shell: true, desktop_browser: true, system_intents: false}
        ] do
      put_host(host)
      assert Agent.default_tools() == Registry.host_tool_modules()
    end
  end

  test "desktop defaults register no Android intent tools" do
    put_host(nil)
    assert android(Registry.host_tool_modules()) == MapSet.new()
    refute "run_elixir_script" in names(Registry.host_tool_modules())
  end

  test "Android intent tools and run_elixir_script are gated on system_intents?, not webview_browser?" do
    put_host(%{
      shell: false,
      desktop_browser: false,
      webview_browser: false,
      system_intents: true
    })

    mods = Registry.host_tool_modules()
    assert android(mods) == @android_tools
    assert "run_elixir_script" in names(mods)
    refute "browser" in names(mods)
    refute "preview_serve" in names(mods)

    put_host(%{
      shell: false,
      desktop_browser: false,
      webview_browser: true,
      system_intents: false
    })

    mods = Registry.host_tool_modules()
    assert android(mods) == MapSet.new()
    refute "run_elixir_script" in names(mods)
    assert "browser" in names(mods)
    assert "preview_serve" in names(mods)
  end

  test "hosts that only declare webview_browser keep their Android tools (fallback)" do
    put_host(%{shell: false, desktop_browser: false, webview_browser: true, beam_eval: false})
    assert android(Registry.host_tool_modules()) == @android_tools
  end

  defp put_host(nil), do: Application.delete_env(:handbeam, :host)
  defp put_host(host), do: Handbeam.Host.put!(host)

  defp names(mods), do: Enum.map(mods, & &1.name())

  defp android(mods) do
    mods
    |> names()
    |> Enum.filter(&String.starts_with?(&1, "android_"))
    |> MapSet.new()
  end
end

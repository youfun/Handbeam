defmodule HandbeamProbe.Browser.Engine do
  @moduledoc """
  Host-installed WebView engine runner.

  Device uses the NIF. Host tests inject a fake engine and never load NIF.
  """

  @spec install!() :: :ok
  def install! do
    Application.delete_env(:handbeam, :browser_webview)
    Application.put_env(:handbeam, :browser_engine, &command/2)
    Application.put_env(:handbeam, :native_display, &HandbeamProbe.NativeOverlay.command/2)
    _ = HandbeamProbe.Browser.Nif.ensure_loaded()
    :ok
  end

  def command(cmd, opts \\ []) when is_map(cmd) do
    HandbeamProbe.Browser.Nif.command(cmd, opts)
  end
end

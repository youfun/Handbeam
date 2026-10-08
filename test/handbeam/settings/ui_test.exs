defmodule Handbeam.Settings.UITest do
  use Handbeam.DataCase, async: false

  alias Handbeam.Settings.UI

  test "theme defaults to light and round-trips a saved choice" do
    assert UI.theme() == "light"
    assert UI.save_theme("dark") == :ok
    assert UI.theme() == "dark"
    assert UI.save_theme("system") == :ok
    assert UI.theme() == "system"
    assert {:error, _changeset} = UI.save_theme("neon")
    assert UI.theme() == "system"
  end
end

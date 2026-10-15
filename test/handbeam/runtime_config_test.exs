defmodule Handbeam.RuntimeConfigTest do
  use ExUnit.Case, async: false

  test "test endpoint ignores inherited desktop server and port settings" do
    endpoint = Application.fetch_env!(:handbeam, HandbeamWeb.Endpoint)
    refute Keyword.fetch!(endpoint, :server)
    assert endpoint[:http][:port] == 4002

    keys =
      ~w(PHX_SERVER PORT HANDBEAM_COMPUTER_PORT HANDBEAM_COMPUTER_TOKEN HANDBEAM_NOTIFY_PORT HANDBEAM_NOTIFY_TOKEN)

    originals = Map.new(keys, &{&1, System.get_env(&1)})

    System.put_env("PHX_SERVER", "true")
    System.put_env("PORT", "60302")
    System.put_env("HANDBEAM_COMPUTER_PORT", "60303")
    System.put_env("HANDBEAM_COMPUTER_TOKEN", "computer-secret")
    System.put_env("HANDBEAM_NOTIFY_PORT", "60304")
    System.put_env("HANDBEAM_NOTIFY_TOKEN", "notify-secret")

    try do
      config = Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: :test)
      handbeam = Keyword.fetch!(config, :handbeam)

      refute Keyword.has_key?(handbeam, HandbeamWeb.Endpoint)
      refute Keyword.has_key?(handbeam, :computer_use_port)
      refute Keyword.has_key?(handbeam, :computer_use_token)
      refute Keyword.has_key?(handbeam, :macos_notify_port)
      refute Keyword.has_key?(handbeam, :macos_notify_token)
    after
      Enum.each(originals, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end

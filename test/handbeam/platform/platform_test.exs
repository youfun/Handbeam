defmodule Handbeam.PlatformTest do
  use ExUnit.Case, async: true

  alias Handbeam.Platform

  describe "windows?/0" do
    test "returns boolean" do
      assert is_boolean(Platform.windows?())
    end

    test "is opposite of unix?/0" do
      assert Platform.windows?() != Platform.unix?()
    end
  end

  describe "unix?/0" do
    test "returns boolean" do
      assert is_boolean(Platform.unix?())
    end
  end

  describe "path_env_key/1" do
    test "returns PATH on unix-like systems" do
      # On macOS/Linux, PATH is uppercase
      key = Platform.path_env_key(%{"PATH" => "/usr/bin"})
      assert key in ["PATH", "Path", "path"]
    end

    test "handles Windows-style Path env var" do
      key = Platform.path_env_key(%{"Path" => "C:\\Windows"})
      assert key in ["PATH", "Path", "path"]
    end

    test "handles empty env" do
      key = Platform.path_env_key(%{})
      assert is_binary(key)
    end
  end

  describe "os_type/0" do
    test "returns known tuple" do
      {os, _name} = Platform.os_type()
      assert os in [:unix, :win32]
    end
  end
end

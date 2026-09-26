defmodule Handbeam.Tool.Builtin.AndroidFileTest do
  use ExUnit.Case, async: true

  alias Handbeam.Tool.Builtin.AndroidFile

  test "take_path accepts a file name containing consecutive dots" do
    assert {:ok, "foo..bar.txt", nil} = AndroidFile.take_path(%{"path" => "foo..bar.txt"})

    assert {:ok, "docs/notes..v2.md", "desc"} =
             AndroidFile.take_path(%{"path" => "docs/notes..v2.md", "description" => "desc"})
  end

  test "take_path rejects a .. component anywhere in the path" do
    assert {:error, :invalid_path} = AndroidFile.take_path(%{"path" => "a/../b"})
    assert {:error, :invalid_path} = AndroidFile.take_path(%{"path" => "../secret"})
    assert {:error, :invalid_path} = AndroidFile.take_path(%{"path" => "a/b/.."})
    assert {:error, :invalid_path} = AndroidFile.take_path(%{"path" => ".."})
  end

  test "take_path rejects absolute, blank and NUL paths" do
    assert {:error, :invalid_path} = AndroidFile.take_path(%{"path" => "/etc/passwd"})
    assert {:error, :invalid_path} = AndroidFile.take_path(%{"path" => "   "})
    assert {:error, :invalid_path} = AndroidFile.take_path(%{"path" => "a.txt" <> <<0>>})
  end
end

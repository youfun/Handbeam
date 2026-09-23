defmodule Handbeam.Tool.Builtin.GrepTest do
  use ExUnit.Case, async: false

  alias Handbeam.Tool.Builtin.Grep

  @work_dir Path.join(System.tmp_dir!(), "sigil_grep_test_#{System.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@work_dir)
    File.mkdir_p!(@work_dir)
    on_exit(fn -> File.rm_rf!(@work_dir) end)
  end

  test "searches file contents with line numbers" do
    File.write!(
      Path.join(@work_dir, "sample.ex"),
      "defmodule Sample do\n  def hello, do: :world\nend\n"
    )

    {:ok, output} =
      Grep.execute(%{"pattern" => "def hello", "path" => "."}, %{working_directory: @work_dir})

    assert output =~ "sample.ex:2:"
    assert output =~ "def hello"
  end

  test "accepts Claude-style -A and -n arguments" do
    File.write!(Path.join(@work_dir, "sample.ex"), "one\ntwo\nthree\nfour\n")

    {:ok, output} =
      Grep.execute(
        %{"pattern" => "two", "path" => ".", "-n" => true, "-A" => 2, "output_mode" => "content"},
        %{working_directory: @work_dir}
      )

    assert output =~ "sample.ex:2:two"
    assert output =~ "sample.ex-3-three"
    assert output =~ "sample.ex-4-four"
  end

  test "returns no matches as ok" do
    File.write!(Path.join(@work_dir, "sample.ex"), "abc\n")

    assert {:ok, "No matches found"} =
             Grep.execute(%{"pattern" => "missing", "path" => "."}, %{
               working_directory: @work_dir
             })
  end

  test "rejects paths outside workspace" do
    assert {:error, reason} =
             Grep.execute(%{"pattern" => "root", "path" => "/etc"}, %{
               working_directory: @work_dir
             })

    assert reason =~ "outside workspace"
  end

  test "has expected metadata" do
    assert Grep.name() == "grep"
    assert Grep.concurrent?() == true
    assert is_integer(Grep.max_result_chars())
    assert "pattern" in Grep.input_schema().required
  end

  test "elixir fallback finds matches without rg" do
    File.write!(
      Path.join(@work_dir, "sample.ex"),
      "defmodule Sample do\n  def hello, do: :world\nend\n"
    )

    original_path = System.get_env("PATH")

    try do
      System.put_env("PATH", "/nonexistent")

      {:ok, output} =
        Grep.execute(%{"pattern" => "def hello", "path" => "."}, %{working_directory: @work_dir})

      assert output =~ "sample.ex:2:"
      assert output =~ "def hello"
    after
      if original_path, do: System.put_env("PATH", original_path)
    end
  end

  test "elixir fallback glob matches nested files like rg" do
    nested = Path.join([@work_dir, "src", "sample.ex"])
    File.mkdir_p!(Path.dirname(nested))
    File.write!(nested, "defmodule Nested do\n  def hello, do: :ok\nend\n")

    original_path = System.get_env("PATH")

    try do
      System.put_env("PATH", "/nonexistent")

      {:ok, output} =
        Grep.execute(%{"pattern" => "def hello", "path" => ".", "glob" => "*.ex"}, %{
          working_directory: @work_dir
        })

      assert output =~ "src/sample.ex"
      assert output =~ "def hello"
    after
      if original_path, do: System.put_env("PATH", original_path)
    end
  end

  test "elixir fallback glob cannot escape the workspace" do
    outside_dir =
      Path.join(System.tmp_dir!(), "sigil_grep_outside_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside_dir)
    outside = Path.join(outside_dir, "secret.txt")
    File.write!(outside, "outside_workspace_marker\n")

    original_path = System.get_env("PATH")

    try do
      System.put_env("PATH", "/nonexistent")

      {:ok, output} =
        Grep.execute(
          %{"pattern" => "outside_workspace_marker", "path" => ".", "glob" => "../secret.txt"},
          %{working_directory: @work_dir}
        )

      refute output =~ "outside_workspace_marker"
      assert output == "No matches found"
    after
      if original_path, do: System.put_env("PATH", original_path)
      File.rm_rf(outside_dir)
    end
  end
end

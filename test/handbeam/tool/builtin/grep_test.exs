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
      grep(%{"pattern" => "def hello", "path" => "."}, %{working_directory: @work_dir})

    assert output =~ "sample.ex:2:"
    assert output =~ "def hello"
  end

  test "ripgrep keeps the filename when path selects one file" do
    File.write!(Path.join(@work_dir, "sample.ex"), "one\nsingle_file_marker\n")
    bin = Path.join(@work_dir, "bin")
    File.mkdir_p!(bin)
    rg = Path.join(bin, "rg")

    File.write!(
      rg,
      "#!/bin/sh\ncase \" $* \" in *\" --with-filename \"*) printf 'sample.ex:2:single_file_marker\\n'; exit 0;; *) printf '2:single_file_marker\\n'; exit 0;; esac\n"
    )

    File.chmod!(rg, 0o755)
    original_path = System.get_env("PATH")

    try do
      System.put_env("PATH", bin)

      assert {:ok, output} =
               grep(%{"pattern" => "single_file_marker", "path" => "sample.ex"}, %{
                 working_directory: @work_dir
               })

      assert output =~ "sample.ex:2:single_file_marker"
    after
      if original_path, do: System.put_env("PATH", original_path)
    end
  end

  test "accepts Claude-style -A and -n arguments" do
    File.write!(Path.join(@work_dir, "sample.ex"), "one\ntwo\nthree\nfour\n")

    {:ok, output} =
      grep(
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
             grep(%{"pattern" => "missing", "path" => "."}, %{
               working_directory: @work_dir
             })
  end

  test "groups results and continues with an opaque cursor" do
    File.write!(Path.join(@work_dir, "one.txt"), "marker one\nmarker two\n")
    File.write!(Path.join(@work_dir, "two.txt"), "marker three\nmarker four\n")

    assert {:ok, first} =
             grep(%{"pattern" => "marker", "path" => ".", "limit" => 2}, %{
               working_directory: @work_dir
             })

    assert first =~ "== one.txt =="
    assert first =~ "next_cursor:"
    [_, cursor] = Regex.run(~r/next_cursor: (\S+)/, first)

    assert {:ok, second} =
             grep(%{"pattern" => "marker", "path" => ".", "limit" => 2, "cursor" => cursor}, %{
               working_directory: @work_dir
             })

    refute second =~ "marker one"
    refute second =~ "marker two"
    assert second =~ "marker three"
    assert second =~ "marker four"
  end

  test "rejects paths outside workspace" do
    assert {:error, reason} =
             grep(%{"pattern" => "root", "path" => "/etc"}, %{
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
        grep(%{"pattern" => "def hello", "path" => "."}, %{working_directory: @work_dir})

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
        grep(%{"pattern" => "def hello", "path" => ".", "glob" => "*.ex"}, %{
          working_directory: @work_dir
        })

      assert output =~ "src/sample.ex"
      assert output =~ "def hello"
    after
      if original_path, do: System.put_env("PATH", original_path)
    end
  end

  test "elixir fallback expands brace globs" do
    File.write!(Path.join(@work_dir, "one.ex"), "shared_marker\n")
    File.write!(Path.join(@work_dir, "two.heex"), "shared_marker\n")
    File.write!(Path.join(@work_dir, "three.css"), "shared_marker\n")

    without_rg(fn ->
      assert {:ok, output} =
               grep(
                 %{"pattern" => "shared_marker", "path" => ".", "glob" => "*.{ex,heex}"},
                 %{working_directory: @work_dir}
               )

      assert output =~ "one.ex"
      assert output =~ "two.heex"
      refute output =~ "three.css"
    end)
  end

  test "elixir fallback skips dependency and build directories" do
    for dir <- ["deps", "node_modules", "_build", ".git", "build", "tmp"] do
      File.mkdir_p!(Path.join(@work_dir, dir))
      File.write!(Path.join([@work_dir, dir, "ignored.ex"]), "ignored_vendor_marker\n")
    end

    without_rg(fn ->
      assert {:ok, "No matches found"} =
               grep(%{"pattern" => "ignored_vendor_marker", "path" => "."}, %{
                 working_directory: @work_dir
               })
    end)
  end

  test "uses the same ExFff inventory instead of a separate git file list" do
    git = System.find_executable("git")

    if git do
      File.mkdir_p!(Path.join([@work_dir, "desktop", "Resources", "generated"]))
      File.write!(Path.join(@work_dir, "visible.ex"), "visible_inventory_marker\n")

      File.write!(
        Path.join([@work_dir, "desktop", "Resources", "generated", "bundle.js"]),
        "ignored_inventory_marker\n"
      )

      File.write!(
        Path.join([@work_dir, "desktop", ".gitignore"]),
        "Resources/generated/**\n"
      )

      {_output, 0} = System.cmd(git, ["init", "-q", @work_dir])

      assert {:ok, indexed} =
               grep(%{"pattern" => "ignored_inventory_marker", "path" => "."}, %{
                 working_directory: @work_dir
               })

      assert indexed =~ "desktop/Resources/generated/bundle.js"

      assert {:ok, visible} =
               grep(%{"pattern" => "visible_inventory_marker", "path" => "."}, %{
                 working_directory: @work_dir
               })

      assert visible =~ "visible.ex"
    end
  end

  test "elixir fallback does not follow workspace symlinks" do
    outside_dir =
      Path.join(System.tmp_dir!(), "sigil_grep_symlink_#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside_dir)
    File.write!(Path.join(outside_dir, "secret.txt"), "symlink_secret_marker\n")
    File.ln_s!(outside_dir, Path.join(@work_dir, "linked"))

    try do
      without_rg(fn ->
        assert {:ok, "No matches found"} =
                 grep(%{"pattern" => "symlink_secret_marker", "path" => "."}, %{
                   working_directory: @work_dir
                 })
      end)
    after
      File.rm_rf!(outside_dir)
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
        grep(
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

  defp grep(input, context) do
    workspace = context[:working_directory]
    {:ok, index} = ExFff.Index.ensure_started(workspace)
    ExFff.Index.refresh(index)
    assert :ok = ExFff.Index.await_index(index, 5_000)
    Grep.execute(input, context)
  end

  defp without_rg(fun) do
    original_path = System.get_env("PATH")

    try do
      System.put_env("PATH", "/nonexistent")
      fun.()
    after
      if original_path, do: System.put_env("PATH", original_path)
    end
  end

  test "rejects a sensitive search root and does not return workspace secret files" do
    File.write!(Path.join(@work_dir, ".env"), "SECRET_MARKER_DO_NOT_LEAK\n")
    File.write!(Path.join(@work_dir, "app.ex"), "visible_marker\n")
    ssh = Path.join(@work_dir, ".ssh")
    File.mkdir_p!(ssh)
    File.write!(Path.join(ssh, "id_rsa"), "SECRET_KEY_DO_NOT_LEAK\n")

    assert {:error, "sensitive path blocked"} =
             grep(%{"pattern" => "SECRET", "path" => ".ssh"}, %{
               working_directory: @work_dir
             })

    {:ok, visible} =
      grep(%{"pattern" => "visible_marker", "path" => "."}, %{
        working_directory: @work_dir
      })

    assert visible =~ "visible_marker"
    refute visible =~ "SECRET_MARKER_DO_NOT_LEAK"

    assert {:ok, "No matches found"} =
             grep(%{"pattern" => "SECRET_", "path" => "."}, %{
               working_directory: @work_dir
             })
  end
end

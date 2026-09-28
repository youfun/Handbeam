defmodule Handbeam.Tool.Builtin.FileSearchTest do
  @moduledoc """
  Tests for the FileSearch builtin tool.
  """

  use ExUnit.Case, async: false

  alias Handbeam.Tool.Builtin.FileSearch

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "sigil_file_search_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))

    File.write!(Path.join(tmp_dir, "lib/user.ex"), "module")
    File.write!(Path.join(tmp_dir, "lib/user_controller.ex"), "module")
    File.write!(Path.join(tmp_dir, "test/user_test.exs"), "module")

    {:ok, index} = ExFff.Index.ensure_started(tmp_dir)
    assert :ok = ExFff.Index.await_index(index)

    on_exit(fn ->
      case ExFff.Index.ensure_started(tmp_dir) do
        {:ok, pid} ->
          if Process.alive?(pid) do
            GenServer.stop(pid)
          end

        _ ->
          :ok
      end

      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "tool metadata" do
    test "has correct name" do
      assert FileSearch.name() == "file_search"
    end

    test "description names fuzzy search" do
      assert FileSearch.description() =~ "fuzzy file search"
    end

    test "input_schema requires query" do
      schema = FileSearch.input_schema()
      assert schema.type == "object"
      assert "query" in schema.required
      # Property keys are atoms in the map
      assert Map.has_key?(schema.properties, :query)
    end

    test "max_result_chars is a positive integer" do
      assert is_integer(FileSearch.max_result_chars())
      assert FileSearch.max_result_chars() > 0
    end
  end

  describe "execute/2" do
    test "returns error when query is missing" do
      {:error, reason} = FileSearch.execute(%{}, %{working_directory: "/tmp"})
      assert reason =~ "required"
    end

    test "requires an explicit workspace directory" do
      assert {:error, "working_directory is required"} =
               FileSearch.execute(%{"query" => "user"}, %{})
    end

    test "returns results for valid query", %{tmp_dir: tmp_dir} do
      {:ok, output} = FileSearch.execute(%{"query" => "user"}, %{working_directory: tmp_dir})

      assert output =~ "Found"
      assert output =~ "user"
      assert output =~ "ms"
    end

    test "includes score in output", %{tmp_dir: tmp_dir} do
      {:ok, output} = FileSearch.execute(%{"query" => "user"}, %{working_directory: tmp_dir})

      # Output format: "1.\tpath\t(score)"
      assert output =~ "\t("
      assert output =~ ")"
    end

    test "respects limit option", %{tmp_dir: tmp_dir} do
      {:ok, output} =
        FileSearch.execute(%{"query" => "*.ex", "limit" => 1}, %{working_directory: tmp_dir})

      # Only one numbered result
      assert output =~ "1."
      refute output =~ "2."
    end

    test "supports path, exclude, and cursor pagination", %{tmp_dir: tmp_dir} do
      assert {:ok, first} =
               FileSearch.execute(%{"query" => "user", "path" => "lib", "limit" => 1}, %{
                 working_directory: tmp_dir
               })

      assert first =~ "next_cursor:"
      refute first =~ "test/user_test.exs"
      [_, cursor] = Regex.run(~r/next_cursor: (\S+)/, first)
      first_result = first |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "1.\t"))

      assert {:ok, second} =
               FileSearch.execute(
                 %{
                   "query" => "user",
                   "path" => "lib",
                   "limit" => 1,
                   "cursor" => cursor
                 },
                 %{working_directory: tmp_dir}
               )

      refute second =~ first_result

      assert {:ok, excluded} =
               FileSearch.execute(
                 %{"query" => "user", "path" => "lib", "exclude" => ["controller"]},
                 %{working_directory: tmp_dir}
               )

      refute excluded =~ "lib/user_controller.ex"
    end

    test "supports extension filter", %{tmp_dir: tmp_dir} do
      {:ok, output} = FileSearch.execute(%{"query" => "user *.ex"}, %{working_directory: tmp_dir})

      assert output =~ "Found"
      assert output =~ "user"
    end

    test "supports exclude pattern", %{tmp_dir: tmp_dir} do
      {:ok, output} =
        FileSearch.execute(%{"query" => "user !test/"}, %{working_directory: tmp_dir})

      # Results should not include test/ paths (header contains query string, skip it)
      lines = String.split(output, "\n")
      result_lines = Enum.drop_while(lines, &String.starts_with?(&1, "#"))

      Enum.each(result_lines, fn line ->
        if line != "" do
          refute line =~ "test/"
        end
      end)

      assert output =~ "lib/user"
    end

    test "returns no-results message for empty results", %{tmp_dir: tmp_dir} do
      {:ok, output} =
        FileSearch.execute(%{"query" => "zzz_nonexistent_xyz"}, %{working_directory: tmp_dir})

      assert output =~ "No files found"
    end

    test "marks partial results while the background index is still building", %{tmp_dir: tmp_dir} do
      {:ok, index} = ExFff.Index.ensure_started(tmp_dir)
      :sys.replace_state(index, &%{&1 | status: :indexing})

      assert {:ok, output} =
               FileSearch.execute(%{"query" => "user"}, %{working_directory: tmp_dir})

      assert output =~ "indexing"
      assert output =~ "user"
    end
  end
end

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

    on_exit(fn ->
      # Stop any lingering ExFff.Index GenServer
      if Process.whereis(ExFff.Index) && Process.alive?(Process.whereis(ExFff.Index)) do
        GenServer.stop(ExFff.Index)
      end

      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "tool metadata" do
    test "has correct name" do
      assert FileSearch.name() == "file_search"
    end

    test "description is non-empty" do
      assert is_binary(FileSearch.description())
      assert byte_size(FileSearch.description()) > 0
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
      {:error, reason} = FileSearch.execute(%{}, %{})
      assert reason =~ "required"
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
  end
end

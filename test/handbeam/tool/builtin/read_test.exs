defmodule Handbeam.Tool.Builtin.ReadTest do
  @moduledoc """
  Tests for the read builtin tool.

  Reference: `gong/tools/read.ex` (Gong Read tool behavior)
  Test pattern: hand-written from Gong Read source behavior

  Covers:
    - Basic file reading with line numbering
    - Pagination (offset/limit)
    - File not found
    - Directory error
    - Empty files
    - Long line truncation
    - Offset beyond file end
  """

  use ExUnit.Case, async: true

  alias Handbeam.Tool.Builtin.Read

  @fixtures_dir Path.join(File.cwd!(), "test/fixtures")

  setup_all do
    fixtures = %{
      "_minimal.png" =>
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ),
      "_bom.txt" => <<0xEF, 0xBB, 0xBF, "BOM content">>,
      "截图 2026-02-11.txt" => "chinese filename"
    }

    Enum.each(fixtures, fn {name, content} ->
      File.write!(Path.join(@fixtures_dir, name), content)
    end)

    on_exit(fn ->
      Enum.each(Map.keys(fixtures), &File.rm(Path.join(@fixtures_dir, &1)))
    end)

    :ok
  end

  describe "basic file reading" do
    test "reads a file and numbers lines" do
      {:ok, output, _meta} =
        Read.execute(
          %{"file_path" => Path.join(@fixtures_dir, "sample.txt")},
          %{working_directory: @fixtures_dir}
        )

      assert output =~ "line one"
      assert output =~ "line two"
      assert output =~ "1\t"
      assert output =~ "2\t"
    end

    test "[BDD-READ-003] 空文件读取" do
      # Create temp empty file
      tmp = Path.join(@fixtures_dir, "_empty.txt")
      File.write!(tmp, "")

      try do
        {:ok, output, _meta} =
          Read.execute(
            %{"file_path" => tmp},
            %{working_directory: @fixtures_dir}
          )

        assert output == ""
      after
        File.rm(tmp)
      end
    end

    test "returns error for non-existent file" do
      {:error, reason} =
        Read.execute(
          %{"file_path" => "nonexistent.txt"},
          %{working_directory: @fixtures_dir}
        )

      assert reason =~ "No such file"
    end

    test "[BDD-READ-020] 目录路径拒绝" do
      {:error, reason} =
        Read.execute(
          %{"file_path" => @fixtures_dir},
          %{working_directory: Path.dirname(@fixtures_dir)}
        )

      assert reason =~ "Is a directory"
    end
  end

  describe "pagination" do
    test "applies offset and limit" do
      {:ok, output, _meta} =
        Read.execute(
          %{"file_path" => Path.join(@fixtures_dir, "sample.txt"), "offset" => 3, "limit" => 2},
          %{working_directory: @fixtures_dir}
        )

      assert output =~ "line three"
      assert output =~ "line four"
      refute output =~ "line one"
      refute output =~ "line five"
    end

    test "shows continuation hint when more lines exist" do
      {:ok, output, _meta} =
        Read.execute(
          %{"file_path" => Path.join(@fixtures_dir, "sample.txt"), "offset" => 1, "limit" => 3},
          %{working_directory: @fixtures_dir}
        )

      assert output =~ "more lines"
      assert output =~ "offset="
    end

    test "returns error when offset exceeds file length" do
      {:error, reason} =
        Read.execute(
          %{
            "file_path" => Path.join(@fixtures_dir, "sample.txt"),
            "offset" => 1000,
            "limit" => 5
          },
          %{working_directory: @fixtures_dir}
        )

      assert reason =~ "Offset"
      assert reason =~ "beyond"
    end
  end

  describe "long line truncation" do
    test "truncates lines exceeding max_line_length" do
      {:ok, output, _meta} =
        Read.execute(
          %{"file_path" => Path.join(@fixtures_dir, "long_lines.txt")},
          %{working_directory: @fixtures_dir}
        )

      assert output =~ "truncated"
    end
  end

  describe "image detection" do
    test "[BDD-READ-012] PNG MIME 类型检测" do
      png_path = Path.join(@fixtures_dir, "_minimal.png")

      {:ok, output, metadata} =
        Read.execute(
          %{"file_path" => png_path},
          %{working_directory: @fixtures_dir}
        )

      assert output =~ "[Image:"
      assert output =~ "image/png"
      assert metadata.mime_type == "image/png"
      assert is_binary(metadata.data)
    end

    test "[BDD-READ-013] 非图片但图片扩展名" do
      tmp = Path.join(@fixtures_dir, "_fake.png")
      File.write!(tmp, "this is plain text")

      try do
        {:ok, output, _meta} =
          Read.execute(
            %{"file_path" => tmp},
            %{working_directory: @fixtures_dir}
          )

        # Read as text, not as image — output has line numbers
        assert output =~ "this is plain text"
        refute output =~ "[Image:"
      after
        File.rm(tmp)
      end
    end

    test "[BDD-READ-023] .jpg 扩展但 PNG MIME" do
      png_path = Path.join(@fixtures_dir, "_minimal.png")
      tmp = Path.join(@fixtures_dir, "_photo.jpg")
      File.cp!(png_path, tmp)

      try do
        {:ok, output, metadata} =
          Read.execute(
            %{"file_path" => tmp},
            %{working_directory: @fixtures_dir}
          )

        assert output =~ "[Image:"
        assert metadata.mime_type == "image/png"
      after
        File.rm(tmp)
      end
    end
  end

  describe "binary file rejection" do
    test "[BDD-READ-022] 二进制文件拒绝读取" do
      bin_path = Path.join(@fixtures_dir, "_binary.bin")

      {:error, reason} =
        Read.execute(
          %{"file_path" => bin_path},
          %{working_directory: @fixtures_dir}
        )

      assert reason =~ "Binary file"
    end
  end

  describe "encoding & special filenames" do
    test "[BDD-READ-018] 中文/特殊字符文件名" do
      name = "截图 2026-02-11.txt"
      path = Path.join(@fixtures_dir, name)

      {:ok, output, _meta} =
        Read.execute(
          %{"file_path" => path},
          %{working_directory: @fixtures_dir}
        )

      assert output =~ "chinese filename"
    end

    test "[BDD-READ-021] BOM 文件读取跳过 BOM" do
      bom_path = Path.join(@fixtures_dir, "_bom.txt")

      {:ok, output, _meta} =
        Read.execute(
          %{"file_path" => bom_path},
          %{working_directory: @fixtures_dir}
        )

      assert output =~ "BOM content"
      # BOM bytes (\xEF\xBB\xBF) must NOT appear in output
      refute output =~ "\xEF\xBB\xBF"
    end
  end

  describe "security — workspace boundary" do
    test "rejects reading files outside the workspace" do
      outside = "/etc/passwd"

      {:error, reason} =
        Read.execute(
          %{"file_path" => outside},
          %{working_directory: @fixtures_dir}
        )

      assert reason =~ "Path traversal" or reason =~ "outside workspace"
    end

    test "rejects relative path traversal (../)" do
      {:error, reason} =
        Read.execute(
          %{"file_path" => "../../etc/passwd"},
          %{working_directory: @fixtures_dir}
        )

      assert reason =~ "Path traversal" or reason =~ "outside workspace"
    end

    test "rejects absolute path that resolves outside workspace" do
      {:error, reason} =
        Read.execute(
          %{"file_path" => "/etc/hosts"},
          %{working_directory: @fixtures_dir}
        )

      assert reason =~ "Path traversal" or reason =~ "outside workspace"
    end
  end

  describe "result metadata" do
    test "text file returns full metadata" do
      path = Path.join(@fixtures_dir, "sample.txt")

      {:ok, output, meta} =
        Read.execute(
          %{"file_path" => path},
          %{working_directory: @fixtures_dir}
        )

      assert meta.file_path == path
      assert meta.binary == false
      assert is_integer(meta.total_lines) and meta.total_lines > 0
      assert is_integer(meta.total_bytes) and meta.total_bytes > 0
      assert meta.truncated == false
      assert meta.offset == 1
      # Content still present and unchanged
      assert output =~ "line one"
    end

    test "truncated metadata when pagination leaves more lines" do
      path = Path.join(@fixtures_dir, "sample.txt")

      {:ok, _output, meta} =
        Read.execute(
          %{"file_path" => path, "offset" => 1, "limit" => 1},
          %{working_directory: @fixtures_dir}
        )

      assert meta.truncated == true
      assert meta.offset == 1
    end

    test "image file returns metadata with binary flag" do
      png_path = Path.join(@fixtures_dir, "_minimal.png")

      {:ok, output, meta} =
        Read.execute(
          %{"file_path" => png_path},
          %{working_directory: @fixtures_dir}
        )

      assert meta.file_path == png_path
      assert meta.binary == true
      assert is_nil(meta.total_lines)
      assert is_integer(meta.total_bytes) and meta.total_bytes > 0
      assert meta.truncated == false
      assert meta.offset == 0
      # Image-specific fields preserved
      assert meta.mime_type == "image/png"
      assert is_binary(meta.data)
      assert output =~ "[Image:"
    end

    test "empty file metadata" do
      tmp = Path.join(@fixtures_dir, "_empty_meta.txt")
      File.write!(tmp, "")

      try do
        {:ok, output, meta} =
          Read.execute(
            %{"file_path" => tmp},
            %{working_directory: @fixtures_dir}
          )

        assert meta.total_lines == 0
        assert meta.binary == false
        assert meta.truncated == false
        assert output == ""
      after
        File.rm(tmp)
      end
    end

    test "offset preserved in metadata" do
      path = Path.join(@fixtures_dir, "sample.txt")

      {:ok, _output, meta} =
        Read.execute(
          %{"file_path" => path, "offset" => 5},
          %{working_directory: @fixtures_dir}
        )

      assert meta.offset == 5
    end
  end

  describe "tilde expansion" do
    test "expands ~ in file paths" do
      tmp_name = "_sigil_tilde_test_#{System.unique_integer([:positive])}.txt"
      tmp_path = Path.join(System.user_home!(), tmp_name)
      File.write!(tmp_path, "hello from tilde\n")

      try do
        {:ok, output, _meta} =
          Read.execute(
            %{"file_path" => "~/#{tmp_name}"},
            %{working_directory: System.user_home!()}
          )

        assert output =~ "hello from tilde"
      after
        File.rm(tmp_path)
      end
    end
  end

  describe "tool metadata" do
    test "has correct name" do
      assert Read.name() == "read"
    end

    test "has description" do
      assert is_binary(Read.description())
    end

    test "has input_schema with file_path required" do
      schema = Read.input_schema()
      assert schema.type == "object"
      assert Map.has_key?(schema.properties, :file_path)
    end

    test "declares max_result_chars" do
      assert is_integer(Read.max_result_chars()) || Read.max_result_chars() == :unlimited
    end
  end
end

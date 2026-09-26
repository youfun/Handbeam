defmodule Handbeam.Tool.Builtin.Read do
  alias Handbeam.Agent.Tool.Helpers

  @moduledoc """
  Read file contents with pagination support.

  Supports offset/limit pagination, line numbering, long-line truncation,
  binary file detection, and image file preview.
  """

  @behaviour Handbeam.Agent.Tool

  @max_output_bytes 50_000
  @max_line_length 2_000
  @default_limit 2_000

  @impl true
  def name, do: "read"

  @impl true
  def description do
    "Read file contents. Supports pagination with offset/limit. " <>
      "Detects binary and image files automatically."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        file_path: %{type: "string", description: "Absolute or relative file path"},
        offset: %{
          type: "integer",
          description: "Line number to start from (1-based, 0 = from start)",
          default: 0
        },
        limit: %{type: "integer", description: "Maximum lines to read", default: @default_limit}
      },
      required: ["file_path"]
    }
  end

  @impl true
  def max_result_chars, do: @max_output_bytes + 1_000

  @impl true
  def concurrent?, do: true

  @impl true
  def execute(%{"file_path" => file_path} = input, context) do
    offset = Map.get(input, "offset", 0)
    limit = Map.get(input, "limit", @default_limit)

    with {:ok, resolved} <-
           Handbeam.Agent.Tool.resolve_path(Helpers.expand_tilde(file_path), context),
         :ok <- validate_exists(resolved),
         :ok <- validate_not_dir(resolved),
         :ok <- validate_readable(resolved) do
      if binary_file?(resolved) do
        read_image(resolved)
      else
        read_text(resolved, offset, limit)
      end
    end
  end

  def execute(_input, _context) do
    {:error, "file_path is required"}
  end

  # ── Path handling ──

  # ── Validation ──

  defp validate_exists(path) do
    if File.exists?(path), do: :ok, else: {:error, "#{path}: No such file"}
  end

  defp validate_not_dir(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} -> {:error, "#{path}: Is a directory"}
      _ -> :ok
    end
  end

  defp validate_readable(path) do
    Handbeam.Security.PathValidator.validate_readable(path)
  end

  # ── Binary detection ──

  defp binary_file?(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        chunk = IO.binread(device, 8192)
        File.close(device)
        has_null_byte?(chunk)

      _ ->
        false
    end
  end

  defp has_null_byte?(:eof), do: false
  defp has_null_byte?(<<>>), do: false
  defp has_null_byte?(<<0, _::binary>>), do: true
  defp has_null_byte?(<<_, rest::binary>>), do: has_null_byte?(rest)

  # ── BOM handling ──

  defp strip_utf8_bom([<<0xEF, 0xBB, 0xBF, rest::binary>> | tail]), do: [rest | tail]
  defp strip_utf8_bom(lines), do: lines

  # ── Image handling ──

  defp read_image(path) do
    total_bytes = File.stat!(path).size

    case detect_image(path) do
      {:ok, mime} ->
        data = File.read!(path)
        base64 = Base.encode64(data)

        metadata =
          build_metadata(path, true, nil, total_bytes, false, 0)
          |> Map.put(:mime_type, mime)
          |> Map.put(:data, base64)

        {:ok, "[Image: #{mime}, #{byte_size(data)} bytes]", metadata}

      :error ->
        {:error, "#{path}: Binary file, cannot display as text"}
    end
  end

  defp detect_image(path) do
    case File.read(path) do
      {:ok, <<0x89, 0x50, 0x4E, 0x47, _::binary>>} -> {:ok, "image/png"}
      {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} -> {:ok, "image/jpeg"}
      {:ok, <<"GIF8", _::binary>>} -> {:ok, "image/gif"}
      {:ok, <<"RIFF", _::32, "WEBP", _::binary>>} -> {:ok, "image/webp"}
      _ -> :error
    end
  end

  # ── Text reading ──

  defp read_text(path, offset, limit) do
    lines = File.stream!(path) |> Enum.to_list() |> strip_utf8_bom()
    total_lines = length(lines)
    start_line = if offset <= 0, do: 1, else: offset
    total_bytes = File.stat!(path).size

    cond do
      total_lines == 0 ->
        metadata =
          build_metadata(path, false, 0, total_bytes, false, start_line)

        {:ok, "", metadata}

      start_line > total_lines ->
        {:error, "Offset #{start_line} beyond file end (#{total_lines} lines)"}

      true ->
        output = format_lines(lines, start_line, limit, total_lines)

        # Compute whether the output was truncated (pagination)
        available = total_lines - start_line + 1
        output_lines = min(limit, available)
        remaining = available - output_lines
        truncated = remaining > 0

        metadata =
          build_metadata(path, false, total_lines, total_bytes, truncated, start_line)

        {:ok, output, metadata}
    end
  end

  # ── Metadata ──

  defp build_metadata(file_path, binary, total_lines, total_bytes, truncated, offset) do
    %{
      file_path: file_path,
      binary: binary,
      total_lines: total_lines,
      total_bytes: total_bytes,
      truncated: truncated,
      offset: offset
    }
  end

  defp format_lines(lines, start_line, limit, total_lines) do
    selected =
      lines
      |> Enum.slice(start_line - 1, limit)

    output_lines = length(selected)
    remaining = total_lines - (start_line - 1) - output_lines

    formatted =
      selected
      |> Enum.with_index(start_line)
      |> Enum.map_join("\n", fn {line, num} ->
        clean = String.trim_trailing(line, "\n") |> String.trim_trailing("\r")
        truncated = truncate_long_line(clean)
        "#{String.pad_leading(Integer.to_string(num), 6)}\t#{truncated}"
      end)

    hint =
      if remaining > 0 do
        next_offset = start_line + output_lines
        "\n\n[#{remaining} more lines. Use offset=#{next_offset} to continue.]"
      else
        ""
      end

    formatted <> hint
  end

  defp truncate_long_line(line) when byte_size(line) <= @max_line_length, do: line

  defp truncate_long_line(line) do
    truncated = String.slice(line, 0, @max_line_length)
    "#{truncated}... [#{String.length(line) - @max_line_length} chars truncated]"
  end
end

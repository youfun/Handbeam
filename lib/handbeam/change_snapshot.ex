defmodule Handbeam.ChangeSnapshot do
  @moduledoc """
  Builds reversible file-change snapshots for WebUI diff review.

  The UI diff can be clipped for readability, so revert must rely on these
  full before/after snapshots and hashes instead of diff lines.
  """

  @max_snapshot_bytes 1_000_000
  @diff_context_lines 3

  @type snapshot :: map()

  @spec sha256(binary() | nil) :: String.t() | nil
  def sha256(nil), do: nil

  def sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @spec build_edit_snapshot(Path.t(), binary(), binary(), [map()] | nil, keyword()) :: snapshot()
  def build_edit_snapshot(file_path, before_content, after_content, diff_lines \\ nil, opts \\ []) do
    diff_lines = diff_lines || diff_lines(before_content, after_content)
    build_snapshot("edit", file_path, true, before_content, after_content, diff_lines, opts)
  end

  @spec build_write_snapshot(Path.t(), binary() | nil, binary(), keyword()) :: snapshot()
  def build_write_snapshot(file_path, before_content, after_content, opts \\ []) do
    existed_before = is_binary(before_content)
    diff_lines = diff_lines(before_content || "", after_content)

    build_snapshot(
      "write",
      file_path,
      existed_before,
      before_content,
      after_content,
      diff_lines,
      opts
    )
  end

  @spec diff_lines(binary(), binary()) :: [map()] | nil
  def diff_lines(old, new) when old == new, do: nil

  def diff_lines(old, new) when is_binary(old) and is_binary(new) do
    old
    |> diff(new)
    |> clip_diff_context()
    |> Enum.flat_map(fn
      {:eq, lines} -> Enum.map(lines, &%{"type" => "eq", "text" => &1})
      {:del, lines} -> Enum.map(lines, &%{"type" => "del", "text" => &1})
      {:ins, lines} -> Enum.map(lines, &%{"type" => "ins", "text" => &1})
      {:skip, count} -> [%{"type" => "skip", "text" => "... #{count} unchanged lines ..."}]
    end)
  end

  defp build_snapshot(
         change_type,
         file_path,
         existed_before,
         before_content,
         after_content,
         diff_lines,
         opts
       ) do
    max_bytes = Keyword.get(opts, :max_snapshot_bytes, @max_snapshot_bytes)
    total_bytes = byte_size(before_content || "") + byte_size(after_content || "")
    reversible = total_bytes <= max_bytes
    change_id = Keyword.get_lazy(opts, :change_id, fn -> "chg_" <> Ecto.UUID.generate() end)

    %{
      change_id: change_id,
      change_type: change_type,
      file_path: file_path,
      existed_before: existed_before,
      before_sha256: sha256(before_content),
      after_sha256: sha256(after_content),
      before_content: if(reversible, do: before_content, else: nil),
      after_content: if(reversible, do: after_content, else: nil),
      diff_lines: diff_lines,
      reversible: reversible,
      revert_status: if(reversible, do: "available", else: "unavailable"),
      revert_reason: if(reversible, do: nil, else: "too_large")
    }
  end

  defp diff(old, new) do
    old_lines = String.split(old, "\n")
    new_lines = String.split(new, "\n")
    List.myers_difference(old_lines, new_lines)
  end

  defp clip_diff_context(diff) do
    change_indices =
      diff
      |> Enum.with_index()
      |> Enum.filter(fn {{type, _lines}, _i} -> type != :eq end)
      |> Enum.map(fn {_chunk, i} -> i end)

    if change_indices == [] do
      diff
    else
      first = hd(change_indices)
      last = List.last(change_indices)
      ctx = @diff_context_lines

      Enum.flat_map(Enum.with_index(diff), fn {{type, lines}, i} ->
        case type do
          :eq ->
            cond do
              i < first -> clip_before(lines, ctx)
              i > last -> clip_after(lines, ctx)
              true -> clip_middle(lines, ctx)
            end

          :del ->
            [{:del, lines}]

          :ins ->
            [{:ins, lines}]
        end
      end)
    end
  end

  defp clip_before(lines, ctx) when length(lines) <= ctx, do: [{:eq, lines}]

  defp clip_before(lines, ctx) do
    keep = Enum.take(lines, -ctx)
    skipped = length(lines) - ctx
    [{:skip, skipped}, {:eq, keep}]
  end

  defp clip_after(lines, ctx) when length(lines) <= ctx, do: [{:eq, lines}]

  defp clip_after(lines, ctx) do
    keep = Enum.take(lines, ctx)
    skipped = length(lines) - ctx
    [{:eq, keep}, {:skip, skipped}]
  end

  defp clip_middle(lines, ctx) when length(lines) <= ctx * 2, do: [{:eq, lines}]

  defp clip_middle(lines, ctx) do
    head = Enum.take(lines, ctx)
    tail = Enum.take(lines, -ctx)
    skipped = length(lines) - ctx * 2
    [{:eq, head}, {:skip, skipped}, {:eq, tail}]
  end
end

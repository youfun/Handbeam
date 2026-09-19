defmodule HandbeamProbe.WorkTimeline do
  @moduledoc """
  Display-only projection of transcript entries into work segments and activities.

  User messages are hard boundaries. Late tool results update their existing entry,
  never move into the next segment. Expansion preferences are independent of status.
  """
  use Gettext, backend: HandbeamProbe.Gettext
  alias Handbeam.TranscriptEntry
  alias HandbeamProbe.Bridge.Payload
  alias HandbeamWeb.WorkspaceHelper

  @projection_keys ~w(work_segment_id work_segment_first work_segment_open work_hidden
    work_boundary_summary work_group_id work_group_first work_group_complete work_collapsed
    work_summary work_failed work_cancelled work_edit work_added work_removed tool_output_open)

  def project(entries, groups \\ %{}, segments \\ %{}, outputs \\ %{}) do
    entries
    |> Enum.map(&Map.drop(&1, @projection_keys))
    |> Enum.map_reduce({0, false}, fn entry, {index, final?} ->
      index = if entry["content_type"] == "user_msg" or final?, do: index + 1, else: index
      {{index, entry}, {index, entry["phase"] == "final"}}
    end)
    |> elem(0)
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.map(fn chunk -> Enum.map(chunk, &elem(&1, 1)) end)
    |> then(fn chunks ->
      chunks
      |> Enum.chunk_every(2, 1, [nil])
      |> Enum.flat_map(fn [entries, next] ->
        interrupted? = next != nil and interrupted_user?(hd(next))
        project_segment(entries, groups, segments, outputs, interrupted?)
      end)
    end)
  end

  defp project_segment(entries, groups, segments, outputs, interrupted?) do
    entries =
      entries
      |> Enum.chunk_by(&activity_key/1)
      |> Enum.flat_map(&project_activity(&1, groups, outputs))

    work = Enum.filter(entries, &(&1["content_type"] in ["assistant_msg", "tool"]))
    last = List.last(work)

    answer? =
      last != nil and last["content_type"] == "assistant_msg" and
        last["phase"] != "commentary" and not interrupted?

    process = if answer?, do: Enum.drop(work, -1), else: work

    if process == [] do
      entries
    else
      id = hd(process)["id"]
      complete? = answer? and (last["phase"] == "final" or last["status"] == "completed")
      open? = Map.get(segments, id, not (complete? or interrupted?))
      process_ids = MapSet.new(process, & &1["id"])
      last_activity = process |> Enum.filter(& &1["work_group_first"]) |> List.last()

      Enum.map(entries, fn entry ->
        if MapSet.member?(process_ids, entry["id"]) do
          entry
          |> Map.put("work_segment_id", id)
          |> Map.put("work_segment_first", entry["id"] == id)
          |> Map.put("work_segment_open", open?)
          |> Map.put("work_hidden", not open?)
          |> Map.put("work_boundary_summary", if(interrupted?, do: last_activity))
        else
          entry
        end
      end)
    end
  end

  defp interrupted_user?(%{"delivery" => "steer"}), do: true
  defp interrupted_user?(%{"delivery" => _}), do: false
  defp interrupted_user?(%{"interrupts_work" => true}), do: true
  defp interrupted_user?(_), do: false

  defp activity_key(%{"content_type" => "tool"} = entry) do
    case name(entry) do
      tool when tool in ["edit", "write", "apply_patch"] ->
        {:edit, entry["id"]}

      tool ->
        case WorkspaceHelper.tool_work_kind(tool) do
          kind when kind in [:file, :search] -> :explore
          :command -> :command
          _ -> {:other, entry["id"]}
        end
    end
  end

  defp activity_key(entry), do: {:message, entry["id"]}

  defp project_activity([%{"content_type" => "tool"} | _] = tools, groups, outputs) do
    id = hd(tools)["id"]
    complete? = Enum.all?(tools, &(status(&1) not in ["running", "pending"]))
    open? = Map.get(groups, id, not complete?)
    summary = summary(tools)
    failed = Enum.count(tools, &(status(&1) in ["error", "failed"]))
    cancelled = Enum.count(tools, &(status(&1) == "cancelled"))

    Enum.map(tools, fn entry ->
      entry
      |> Map.put("work_group_id", id)
      |> Map.put("work_group_first", entry["id"] == id)
      |> Map.put("work_group_complete", complete?)
      |> Map.put("work_collapsed", not open?)
      |> Map.put("work_summary", summary)
      |> Map.put("work_failed", failed)
      |> Map.put("work_cancelled", cancelled)
      |> Map.put("work_edit", name(entry) in ["edit", "write", "apply_patch"])
      |> Map.put("work_added", diff_count(entry, "add"))
      |> Map.put("work_removed", diff_count(entry, "remove"))
      |> Map.put("tool_output_open", Map.get(outputs, entry["id"], false))
    end)
  end

  defp project_activity(entries, _groups, _outputs), do: entries

  def summary([entry | _] = tools) do
    case activity_key(entry) do
      {:edit, _} ->
        gettext("Edited %{path}", path: path(entry))

      :explore ->
        counts =
          Enum.frequencies_by(tools, fn tool ->
            cond do
              WorkspaceHelper.tool_work_kind(name(tool)) == :search -> :search
              Path.basename(path(tool)) == "AGENTS.md" -> :guidance
              true -> :file
            end
          end)

        details =
          [{:file, "file"}, {:guidance, "guidance file"}, {:search, "search"}]
          |> Enum.flat_map(fn {key, label} ->
            case Map.get(counts, key, 0) do
              0 -> []
              n -> [count_label(n, label)]
            end
          end)
          |> Enum.join(", ")

        gettext("Explored %{details}", details: details)

      _ ->
        WorkspaceHelper.tool_work_summary(tools)
    end
  end

  def summary([]), do: ""
  defp count_label(n, "file"), do: ngettext("%{count} file", "%{count} files", n)
  defp count_label(n, "search"), do: ngettext("%{count} search", "%{count} searches", n)

  defp count_label(n, "guidance file"),
    do: ngettext("%{count} guidance file", "%{count} guidance files", n)

  # Transcript compat reads (`tool` / `tool_name`, …) go through
  # `Handbeam.TranscriptEntry`; tool `input` is string-keyed once via `Payload`.
  def name(entry), do: TranscriptEntry.tool_name(entry) || "tool"
  def status(entry), do: to_string(TranscriptEntry.tool_status(entry) || "done")

  def path(entry) do
    input = input(entry)

    entry["file_path"] || Payload.first(input, ["file_path", "path"]) ||
      TranscriptEntry.input_summary(entry) || "file"
  end

  def input_label(entry) do
    input = input(entry)
    input["command"] || TranscriptEntry.input_summary(entry) || path(entry)
  end

  defp input(entry), do: entry |> TranscriptEntry.input() |> Payload.string_keys()

  def output(entry) do
    value = entry["output"] || TranscriptEntry.error(entry)

    case value do
      nil -> ""
      text when is_binary(text) -> text
      other -> inspect(other, pretty: true, limit: 100)
    end
  end

  defp diff_count(entry, kind) do
    lines =
      if is_list(entry["diff_lines"]), do: Payload.string_keys(entry["diff_lines"]), else: []

    Enum.count(lines, fn line ->
      type = line["type"]

      to_string(type) in if(kind == "add",
        do: ["add", "added", "ins", "+"],
        else: ["remove", "removed", "delete", "del", "-"]
      )
    end)
  end
end

defmodule HandbeamWeb.WorkspaceLive.ToolProjection do
  @moduledoc false

  alias HandbeamWeb.ChangeHelper

  def start(payload, summarize_input) do
    tool_name = value(payload, :tool) || value(payload, :name) || "unknown"
    tool_use_id = value(payload, :tool_use_id) || tool_name
    input = value(payload, :input) || %{}
    summary = summarize_input.(input, tool_name)

    %{
      tool_name: tool_name,
      entry: %{
        "id" => entry_id(payload, tool_use_id, tool_name),
        "content_type" => "tool",
        "tool_use_id" => tool_use_id,
        "tool" => tool_name,
        "tool_name" => tool_name,
        "status" => :running,
        "tool_status" => "running",
        "input" => input,
        "input_summary" => summary,
        "tool_input_summary" => summary,
        "duration_ms" => nil,
        "tool_duration_ms" => nil,
        "error" => nil,
        "tool_error" => nil,
        "file_path" => nil,
        "diff_lines" => nil,
        "started_at" => System.os_time(:millisecond)
      }
    }
  end

  def finish(payload, base_entry) do
    tool_name = value(payload, :tool) || value(payload, :name) || "unknown"
    duration_ms = value(payload, :duration_ms)
    error = value(payload, :error)
    details = value(payload, :details) || %{}
    file_path = value(payload, :file_path) || value(details, :file_path)
    diff_lines = ChangeHelper.normalize_diff_lines(value(details, :diff_lines))
    change = ChangeHelper.change_from_details(details, file_path, diff_lines, tool_name)
    status = if error, do: :error, else: :done

    entry =
      Map.merge(base_entry, %{
        "tool" => tool_name,
        "tool_name" => tool_name,
        "status" => status,
        "tool_status" => Atom.to_string(status),
        "duration_ms" => duration_ms,
        "tool_duration_ms" => duration_ms,
        "error" => error,
        "tool_error" => error,
        "details" => details,
        "file_path" => file_path,
        "diff_lines" => diff_lines,
        "change" => change,
        "change_id" => Map.get(change, "change_id"),
        "change_type" => Map.get(change, "change_type"),
        "reversible" => Map.get(change, "reversible"),
        "revert_status" => Map.get(change, "revert_status"),
        "revert_reason" => Map.get(change, "revert_reason")
      })

    %{
      entry: entry,
      tool_name: tool_name,
      status: status,
      file_path: file_path,
      diff_lines: diff_lines
    }
  end

  def identity(payload) do
    tool_name = value(payload, :tool) || value(payload, :name) || "unknown"
    tool_use_id = value(payload, :tool_use_id) || tool_name
    id = entry_id(payload, tool_use_id, tool_name)
    {id, tool_name, tool_use_id}
  end

  defp entry_id(payload, tool_use_id, tool_name) do
    if Map.has_key?(payload, :tool_use_id) or Map.has_key?(payload, "tool_use_id"),
      do: "tool-#{tool_use_id}",
      else: "tool-event-#{tool_name}"
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end

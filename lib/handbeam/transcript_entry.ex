defmodule Handbeam.TranscriptEntry do
  @moduledoc """
  Read side of the tool transcript entry compatibility double-write.

  `Handbeam.Agent.TranscriptPersistence` currently writes every tool field under
  two names: the old bare name (`tool`, `status`, `duration_ms`, `error`) and
  the `tool_*` prefixed name that distinguishes tool fields from the assistant
  entry's `status` / `error`. Readers must not spell that fallback themselves
  (`entry["tool_name"] || entry["tool"]`); they call these functions, so the
  writer can later stop emitting the bare names without touching any reader.

  Durable `messages.jsonl` entries normally have string keys, while transient
  LiveView projections and tests can have atom keys. Nothing here writes.
  """

  @type entry :: map()

  @doc "Tool name (`tool_name`, falling back to the legacy `tool`)."
  @spec tool_name(entry()) :: String.t() | nil
  def tool_name(entry), do: first(entry, ["tool_name", "tool", :tool_name, :tool])

  @doc "Tool status (`tool_status`, falling back to the legacy `status`), as written."
  @spec tool_status(entry()) :: String.t() | atom() | nil
  def tool_status(entry), do: first(entry, ["tool_status", "status", :tool_status, :status])

  @doc "Tool duration (`tool_duration_ms`, falling back to the legacy `duration_ms`)."
  @spec duration_ms(entry()) :: integer() | nil
  def duration_ms(entry),
    do: first(entry, ["tool_duration_ms", "duration_ms", :tool_duration_ms, :duration_ms])

  @doc "Tool error (`tool_error`, falling back to the legacy `error`)."
  @spec error(entry()) :: term()
  def error(entry), do: first(entry, ["tool_error", "error", :tool_error, :error])

  @doc "Tool input map (`input`; projections may also carry `tool_input`)."
  @spec input(entry()) :: map()
  def input(entry) do
    case first(entry, ["input", "tool_input", :input, :tool_input]) do
      input when is_map(input) -> input
      _ -> %{}
    end
  end

  @doc "Projection input summary (`tool_input_summary`, falling back to `input_summary`)."
  @spec input_summary(entry()) :: String.t() | nil
  def input_summary(entry),
    do:
      first(entry, [
        "tool_input_summary",
        "input_summary",
        :tool_input_summary,
        :input_summary
      ])

  defp first(entry, keys) when is_map(entry) do
    Enum.find_value(keys, fn key ->
      case Map.get(entry, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp first(_entry, _keys), do: nil
end

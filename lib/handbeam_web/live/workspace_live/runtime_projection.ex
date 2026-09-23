defmodule HandbeamWeb.WorkspaceLive.RuntimeProjection do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream_insert: 3]

  def timeline_insert(socket, entry) do
    expanded = Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())

    timeline =
      socket.assigns.timeline
      |> replace_or_append(entry)
      |> HandbeamWeb.WorkspaceHelper.apply_tool_work_collapse(expanded)

    entry_id = Map.get(entry, "id")
    projected = Enum.find(timeline, &(Map.get(&1, "id") == entry_id)) || entry

    socket
    |> assign(:timeline, timeline)
    |> stream_insert(:timeline, projected)
    |> stream_related_tool_work(timeline, projected)
  end

  def mark_revert_confirm(socket, change_id) do
    socket = assign(socket, :revert_confirm_change_id, change_id)

    timeline =
      Enum.map(socket.assigns.timeline, fn entry ->
        id = change_id_of(entry)

        cond do
          id == change_id and is_binary(id) ->
            Map.put(entry, "revert_confirming", true)

          Map.get(entry, "revert_confirming") == true ->
            Map.delete(entry, "revert_confirming")

          true ->
            entry
        end
      end)

    reinsert_changed(socket, timeline)
  end

  def refresh_file_change(socket, id) when is_binary(id) do
    expanded = Map.get(socket.assigns, :expanded_file_changes, MapSet.new())
    open? = MapSet.member?(expanded, id)

    timeline =
      Enum.map(socket.assigns.timeline, fn entry ->
        if Map.get(entry, "id") == id, do: Map.put(entry, "file_change_open", open?), else: entry
      end)

    case Enum.find(timeline, &(Map.get(&1, "id") == id)) do
      %{} = entry ->
        socket
        |> assign(:timeline, timeline)
        |> stream_insert(:timeline, entry)

      _ ->
        assign(socket, :timeline, timeline)
    end
  end

  def refresh_tool_work(socket, group_id) do
    expanded = Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())

    timeline =
      HandbeamWeb.WorkspaceHelper.apply_tool_work_collapse(socket.assigns.timeline, expanded)

    Enum.reduce(timeline, assign(socket, :timeline, timeline), fn entry, acc ->
      if Map.get(entry, "work_group_id") == group_id,
        do: stream_insert(acc, :timeline, entry),
        else: acc
    end)
  end

  def find_entry(timeline, id), do: Enum.find(timeline, &(Map.get(&1, "id") == id))

  defp change_id_of(entry) do
    change = HandbeamWeb.ChangeHelper.change_from_entry(entry)
    Map.get(change, "change_id")
  end

  defp reinsert_changed(socket, timeline) do
    changed =
      timeline
      |> Enum.zip(socket.assigns.timeline)
      |> Enum.flat_map(fn
        {entry, entry} -> []
        {entry, _old} -> [entry]
      end)

    Enum.reduce(changed, assign(socket, :timeline, timeline), fn entry, acc ->
      stream_insert(acc, :timeline, entry)
    end)
  end

  def finalize_assistant(%{assigns: %{current_assistant_entry_id: nil}} = socket), do: socket

  def finalize_assistant(socket) do
    case find_entry(socket.assigns.timeline, socket.assigns.current_assistant_entry_id) do
      %{"content_type" => "assistant_msg"} = entry ->
        timeline_insert(socket, Map.put(entry, "final", true))

      _ ->
        socket
    end
  end

  def update_messages(socket, chunk) do
    {thinking_text, clean_chunk, buffer} =
      Handbeam.Agent.ThinkingFilter.strip(Map.get(socket.assigns, :think_buffer, ""), chunk)

    socket = assign(socket, :think_buffer, buffer)
    socket = if thinking_text != "", do: assign(socket, :thinking_active, true), else: socket
    socket = if clean_chunk != "", do: assign(socket, :thinking_active, false), else: socket
    update_assistant(socket, clean_chunk)
  end

  def update_status(socket, overrides),
    do: assign(socket, :status_info, Map.merge(socket.assigns.status_info, overrides))

  def maybe_update_status(socket, overrides) do
    if Map.has_key?(socket.assigns, :status_info),
      do: update_status(socket, overrides),
      else: socket
  end

  def usage_tokens(usage) when is_map(usage) do
    input = Map.get(usage, :input_tokens, Map.get(usage, "input_tokens", 0)) || 0
    output = Map.get(usage, :output_tokens, Map.get(usage, "output_tokens", 0)) || 0

    read =
      Map.get(usage, :cache_read_input_tokens, Map.get(usage, "cache_read_input_tokens", 0)) || 0

    write =
      Map.get(
        usage,
        :cache_creation_input_tokens,
        Map.get(usage, "cache_creation_input_tokens", 0)
      ) || 0

    unknown? = Map.get(usage, :unknown?, Map.get(usage, "unknown?", false))

    %{
      input_tokens: if(unknown?, do: :unknown, else: input),
      total_input_tokens:
        if(unknown?,
          do: :unknown,
          else: payload_value(usage, :total_input_tokens, input + read + write)
        ),
      output_tokens: if(unknown?, do: :unknown, else: output),
      cache_read_tokens: read,
      cache_write_tokens: write
    }
  end

  def usage_tokens(_),
    do: %{
      input_tokens: 0,
      total_input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0
    }

  def payload_value(payload, key, default \\ nil)

  def payload_value(payload, key, default) when is_map(payload) and is_atom(key),
    do: Map.get(payload, key, Map.get(payload, Atom.to_string(key), default))

  def payload_value(_payload, _key, default), do: default

  def safe_status(value) when is_atom(value), do: value
  def safe_status("completed"), do: :completed
  def safe_status("running"), do: :running
  def safe_status("error"), do: :error
  def safe_status("max_turns"), do: :max_turns
  def safe_status("interrupted"), do: :interrupted
  def safe_status("awaiting_approval"), do: :awaiting_approval
  def safe_status(_), do: :idle

  def unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  def assistant_final?(entry, running, current_id) do
    cond do
      Map.has_key?(entry, "final") -> truthy?(Map.get(entry, "final"))
      running && Map.get(entry, "id") == current_id && !truthy?(Map.get(entry, "final")) -> false
      true -> true
    end
  end

  defp update_assistant(socket, ""), do: socket

  defp update_assistant(socket, chunk) do
    id = socket.assigns.current_assistant_entry_id || unique_id("msg-assistant")

    entry =
      case find_entry(socket.assigns.timeline, id) do
        nil ->
          %{
            "id" => id,
            "content_type" => "assistant_msg",
            "role" => "assistant",
            "content" => chunk
          }

        existing ->
          Map.put(existing, "content", (Map.get(existing, "content") || "") <> chunk)
      end

    socket |> assign(:current_assistant_entry_id, id) |> timeline_insert(entry)
  end

  defp replace_or_append(timeline, %{"id" => id} = entry) do
    if Enum.any?(timeline, &(Map.get(&1, "id") == id)),
      do:
        Enum.map(timeline, fn existing ->
          if Map.get(existing, "id") == id, do: entry, else: existing
        end),
      else: timeline ++ [entry]
  end

  defp stream_related_tool_work(socket, timeline, %{"work_group_id" => group_id, "id" => id})
       when is_binary(group_id) and group_id != "" do
    Enum.reduce(timeline, socket, fn other, acc ->
      if Map.get(other, "work_group_id") == group_id and Map.get(other, "id") != id,
        do: stream_insert(acc, :timeline, other),
        else: acc
    end)
  end

  defp stream_related_tool_work(socket, _timeline, _entry), do: socket
  defp truthy?(value), do: value in [true, "true", 1, "1"]
end

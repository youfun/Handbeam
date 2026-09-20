defmodule HandbeamWeb.WorkspaceHelper do
  @moduledoc """
  Pure template helper functions extracted from `HandbeamWeb.WorkspaceLive`.

  These functions are value mappers with no dependency on LiveView socket
  or assigns — they can be tested and used independently.
  """

  use Gettext, backend: HandbeamWeb.Gettext

  alias Handbeam.TranscriptEntry

  @doc """
  Returns the CSS class for the status indicator dot.
  """
  def status_dot_class(:idle), do: "idle"
  def status_dot_class(:running), do: "running"
  def status_dot_class(:error), do: "error"
  def status_dot_class(:max_turns), do: "error"
  def status_dot_class(:completed), do: "completed"
  def status_dot_class(_), do: "idle"

  @doc """
  Returns the Unicode icon for a tool execution status.
  """
  def tool_status_icon(:running), do: "◌"
  def tool_status_icon(:done), do: "✓"
  def tool_status_icon(:error), do: "✗"
  def tool_status_icon("running"), do: "◌"
  def tool_status_icon("done"), do: "✓"
  def tool_status_icon("error"), do: "✗"
  def tool_status_icon(_), do: "·"

  @doc """
  Returns the CSS text color class for a tool execution status.
  """
  def tool_status_class(:running), do: "text-warning"
  def tool_status_class(:done), do: "text-success"
  def tool_status_class(:error), do: "text-error"
  def tool_status_class("running"), do: "text-warning"
  def tool_status_class("done"), do: "text-success"
  def tool_status_class("error"), do: "text-error"
  def tool_status_class(_), do: "text-tertiary"

  @doc """
  Returns the CSS border class for a tool execution status.
  """
  def tool_border_class(:running), do: "border-l-warning"
  def tool_border_class(:done), do: "border-l-success"
  def tool_border_class(:error), do: "border-l-error"
  def tool_border_class(_), do: "border border-gray-600"

  @doc """
  Returns the human-readable label for a tool execution status.
  """
  def render_tool_status(:running), do: "running"
  def render_tool_status(:done), do: "done"
  def render_tool_status(:error), do: "error"
  def render_tool_status("running"), do: "running"
  def render_tool_status("done"), do: "done"
  def render_tool_status("error"), do: "error"
  def render_tool_status(_), do: ""

  @doc """
  Counts the number of tool entries in a timeline entry list.
  """
  def tool_entry_count(entries) when is_list(entries) do
    entries
    |> Enum.count(fn entry ->
      Map.get(entry, "content_type") == "tool" or Map.get(entry, :content_type) == "tool"
    end)
  end

  def tool_entry_count(_entries), do: 0

  @doc """
  Returns a truncated summary of the first non-empty message content in a timeline.
  """
  def timeline_summary(entries) when is_list(entries) do
    entries
    |> Enum.reject(
      &(get_in(&1, ["origin", "kind"]) == "thread" or &1["content_type"] == "thread_handoff")
    )
    |> Enum.find_value(fn entry ->
      content = Map.get(entry, "content") || Map.get(entry, :content)
      if is_binary(content) and content != "", do: content
    end)
    |> case do
      nil -> ""
      content -> String.slice(content, 0, 80)
    end
  end

  def timeline_summary(_entries), do: ""

  @user_nav_summary_limit 36

  @doc """
  User turns for the conversation navigator: id, 1-based index, and a short summary.

  Assistant, tool, and system entries are omitted.
  """
  def user_message_nav_items(entries) when is_list(entries) do
    entries
    |> Enum.filter(&user_msg_entry?/1)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {entry, index} ->
      case Map.get(entry, "id") || Map.get(entry, :id) do
        id when is_binary(id) and id != "" ->
          content = Map.get(entry, "content") || Map.get(entry, :content)
          attachments = Map.get(entry, "attachments") || Map.get(entry, :attachments) || []

          [
            %{
              id: id,
              index: index,
              summary: user_message_nav_summary(content, attachments)
            }
          ]

        _ ->
          []
      end
    end)
  end

  def user_message_nav_items(_entries), do: []

  defp user_msg_entry?(entry) when is_map(entry) do
    (Map.get(entry, "content_type") == "user_msg" or Map.get(entry, :content_type) == "user_msg") and
      get_in(entry, ["origin", "kind"]) != "thread"
  end

  defp user_msg_entry?(_entry), do: false

  defp user_message_nav_summary(content, attachments) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      trimmed != "" -> truncate_user_nav_summary(trimmed)
      has_attachments?(attachments) -> gettext("（图片）")
      true -> gettext("（空消息）")
    end
  end

  defp user_message_nav_summary(_content, attachments) do
    if has_attachments?(attachments), do: gettext("（图片）"), else: gettext("（空消息）")
  end

  defp has_attachments?(attachments) when is_list(attachments), do: attachments != []
  defp has_attachments?(_attachments), do: false

  defp truncate_user_nav_summary(text) do
    if String.length(text) > @user_nav_summary_limit do
      String.slice(text, 0, @user_nav_summary_limit) <> "…"
    else
      text
    end
  end

  @doc """
  User-facing install card when a browser tool result is missing-binary.
  """
  def browser_install_prompt(entry) do
    Handbeam.Browser.InstallPrompt.from_entry(entry)
  end

  @doc "Conversation card for a registered preview_id."
  def preview_card(entry) when is_map(entry) do
    details = Map.get(entry, "details") || Map.get(entry, :details) || %{}
    preview_id = map_get(details, "preview_id") || map_get(entry, "preview_id")

    if is_binary(preview_id) do
      %{
        preview_id: preview_id,
        title: map_get(details, "title") || "Preview",
        conversation_id: map_get(details, "conversation_id"),
        preview_path: map_get(details, "preview_path") || "/preview/#{preview_id}"
      }
    end
  end

  def preview_card(_), do: nil

  @doc "Explicit takeover prompt from a browser tool result. Never auto-covers chat."
  def browser_takeover_prompt(entry) when is_map(entry) do
    details = Map.get(entry, "details") || Map.get(entry, :details) || %{}

    if map_get(details, "needs_user") in [true, "true"] do
      %{
        session_id: map_get(details, "session_id"),
        reason: map_get(details, "reason") || "user takeover required"
      }
    end
  end

  def browser_takeover_prompt(_), do: nil

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, known_detail_atom(key))
  end

  defp map_get(_, _), do: nil

  defp known_detail_atom("preview_id"), do: :preview_id
  defp known_detail_atom("title"), do: :title
  defp known_detail_atom("conversation_id"), do: :conversation_id
  defp known_detail_atom("preview_path"), do: :preview_path
  defp known_detail_atom("needs_user"), do: :needs_user
  defp known_detail_atom("session_id"), do: :session_id
  defp known_detail_atom("reason"), do: :reason
  defp known_detail_atom(_), do: nil

  @search_tools ~w(
    grep search file_search glob glob_file_search find rg ripgrep
    semantic_search codebase_search
  )
  @file_tools ~w(read read_file write edit apply_patch list_dir)
  @command_tools ~w(bash shell command)

  @doc """
  Classifies a tool name into `:file`, `:search`, `:command`, or `:other`.
  """
  def tool_work_kind(name) do
    normalized =
      name
      |> to_string()
      |> String.downcase()
      |> String.replace_prefix("ext__", "")

    cond do
      normalized in @search_tools -> :search
      normalized in @file_tools -> :file
      normalized in @command_tools -> :command
      String.contains?(normalized, "search") -> :search
      String.contains?(normalized, "read") -> :file
      String.contains?(normalized, "write") -> :file
      String.contains?(normalized, "edit") -> :file
      String.contains?(normalized, "bash") or String.contains?(normalized, "shell") -> :command
      true -> :other
    end
  end

  @doc """
  Counts completed-work buckets for a list of tool entries.
  """
  def tool_work_counts(tools) when is_list(tools) do
    Enum.reduce(tools, %{files: 0, searches: 0, commands: 0, others: 0}, fn tool, acc ->
      case tool_work_kind(tool_name(tool)) do
        :file -> %{acc | files: acc.files + 1}
        :search -> %{acc | searches: acc.searches + 1}
        :command -> %{acc | commands: acc.commands + 1}
        :other -> %{acc | others: acc.others + 1}
      end
    end)
  end

  def tool_work_counts(_), do: %{files: 0, searches: 0, commands: 0, others: 0}

  @doc """
  Amp-style collapsed summary, e.g. "Explored 1 file, 2 searches".
  """
  def tool_work_summary(tools) when is_list(tools) and tools != [] do
    counts = tool_work_counts(tools)
    details = format_tool_work_details(counts)

    cond do
      counts.files + counts.searches > 0 ->
        gettext("Explored %{details}", details: details)

      counts.commands > 0 and counts.others == 0 ->
        gettext("Ran %{details}", details: details)

      true ->
        gettext("Used %{details}", details: details)
    end
  end

  def tool_work_summary(_), do: ""

  @doc """
  Annotates consecutive tool streaks with collapse metadata.

  Completed groups are collapsed unless `expanded_ids` contains the group id
  (the first tool entry id in that streak).
  """
  def apply_tool_work_collapse(entries, expanded_ids \\ MapSet.new())

  def apply_tool_work_collapse(entries, expanded_ids) when is_list(entries) do
    expanded_ids = MapSet.new(expanded_ids, &to_string/1)

    updates =
      entries
      |> Enum.with_index()
      |> Enum.chunk_by(fn {entry, _idx} -> tool_entry?(entry) end)
      |> Enum.flat_map(fn
        [] ->
          []

        [{entry, _idx} | _rest] = chunk ->
          if tool_entry?(entry) do
            annotate_tool_work_chunk(chunk, expanded_ids)
          else
            []
          end
      end)
      |> Map.new()

    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, idx} ->
      case Map.fetch(updates, idx) do
        {:ok, updated} ->
          updated

        :error ->
          entry
          |> Map.delete("work_group_id")
          |> Map.delete("work_group_first")
          |> Map.delete("work_group_complete")
          |> Map.delete("work_collapsed")
          |> Map.delete("work_summary")
      end
    end)
  end

  def apply_tool_work_collapse(entries, _expanded_ids), do: entries

  defp annotate_tool_work_chunk(chunk, expanded_ids) do
    tools = Enum.map(chunk, &elem(&1, 0))
    first = hd(tools)
    group_id = entry_id(first)
    completed? = Enum.all?(tools, &tool_terminal?/1)
    collapsed? = completed? and group_id != "" and not MapSet.member?(expanded_ids, group_id)
    summary = tool_work_summary(tools)

    Enum.map(chunk, fn {entry, idx} ->
      {idx,
       entry
       |> Map.put("work_group_id", group_id)
       |> Map.put("work_group_first", entry_id(entry) == group_id)
       |> Map.put("work_group_complete", completed?)
       |> Map.put("work_collapsed", collapsed?)
       |> Map.put("work_summary", summary)}
    end)
  end

  defp tool_entry?(entry) when is_map(entry) do
    Map.get(entry, "content_type") == "tool" or Map.get(entry, :content_type) == "tool"
  end

  defp tool_entry?(_), do: false

  defp tool_terminal?(entry) do
    status = TranscriptEntry.tool_status(entry)

    status in [nil, "", :done, :error, "done", "error"]
  end

  defp tool_name(entry) when is_map(entry) do
    TranscriptEntry.tool_name(entry) || "tool"
  end

  defp tool_name(_), do: "tool"

  defp entry_id(entry) when is_map(entry) do
    case Map.get(entry, "id") || Map.get(entry, :id) do
      id when is_binary(id) -> id
      id when is_atom(id) -> Atom.to_string(id)
      id -> to_string(id)
    end
  end

  defp entry_id(_), do: ""

  defp format_tool_work_details(counts) do
    []
    |> maybe_count_part(counts.files, "%{count} file", "%{count} files")
    |> maybe_count_part(counts.searches, "%{count} search", "%{count} searches")
    |> maybe_count_part(counts.commands, "%{count} command", "%{count} commands")
    |> maybe_count_part(counts.others, "%{count} action", "%{count} actions")
    |> Enum.join(", ")
  end

  defp maybe_count_part(parts, count, _one, _other) when count <= 0, do: parts

  defp maybe_count_part(parts, count, one, other) do
    parts ++ [Gettext.ngettext(HandbeamWeb.Gettext, one, other, count)]
  end

  @doc """
  Formats a duration in milliseconds to a human-readable string.
  """
  def format_duration(nil), do: nil
  def format_duration(ms) when ms < 1000, do: "#{ms}ms"
  def format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  @doc """
  Formats a byte count to a human-readable string (B / KB / MB).
  """
  def format_bytes(nil), do: "0 B"
  def format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  def format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 2)} MB"

  @doc """
  Formats tokens with decimal K/M units and at most one decimal place.
  Rounds half up and promotes rounded 1000K to 1M.

  ## Examples

      iex> HandbeamWeb.WorkspaceHelper.format_tokens(5481)
      "5.5K"

      iex> HandbeamWeb.WorkspaceHelper.format_tokens(999_950)
      "1M"
  """
  def format_tokens(tokens) when tokens < 1000, do: Integer.to_string(tokens)
  def format_tokens(tokens) when tokens < 999_950, do: compact_tokens(tokens, 1000, "K")
  def format_tokens(tokens), do: compact_tokens(tokens, 1_000_000, "M")

  defp compact_tokens(tokens, unit, suffix) do
    value = (tokens / unit) |> Float.round(1) |> :erlang.float_to_binary(decimals: 1)
    String.trim_trailing(value, ".0") <> suffix
  end

  @doc """
  Formats the run's token-weighted cache read rate, not a mean of request rates.
  No reported cache activity (or no input) is shown as unavailable.

  ## Examples

      iex> HandbeamWeb.WorkspaceHelper.format_cache_hit_rate(%{total_input_tokens: 1000, cache_read_tokens: 800, cache_write_tokens: 0})
      "80.0%"
  """
  def format_cache_hit_rate(%{
        total_input_tokens: total,
        cache_read_tokens: read,
        cache_write_tokens: write
      })
      when total > 0 and (read > 0 or write > 0) do
    :erlang.float_to_binary(100 * read / total, decimals: 1) <> "%"
  end

  def format_cache_hit_rate(_), do: "—"

  @doc """
  Returns the diff line prefix character for a given diff type.
  """
  def diff_prefix("ins"), do: "+"
  def diff_prefix("del"), do: "-"
  def diff_prefix("skip"), do: "⋯"
  def diff_prefix(_), do: " "

  @doc """
  Reads the value for a key from a map, trying both atom and string forms.
  Returns `default` when the key is not found.
  """
  def file_value(file, key, default) do
    key_str = if is_atom(key), do: Atom.to_string(key), else: key
    Map.get(file, key_str, Map.get(file, key, default))
  end

  @doc """
  Counts the number of archived conversations in a Phoenix LiveView stream entries list.
  """
  def archived_stream_count(stream_entries) when is_list(stream_entries) do
    Enum.count(stream_entries, fn {_, conv} -> conv.archived end)
  end

  def archived_stream_count(_), do: 0

  @doc """
  Renders a file preview as HTML-safe text.

  Returns "" for nil paths, escaped content for workspace files,
  and an error message for files outside the workspace or unreadable files.
  """
  def render_file_preview(path, workspace_root \\ Handbeam.Workspace.root()) do
    if is_nil(path) do
      ""
    else
      case Handbeam.Workspace.resolve(path, workspace_root) do
        {:ok, _} ->
          case File.read(path) do
            {:ok, content} ->
              content
              |> String.slice(0, 10_000)
              |> String.replace("&", "&amp;")
              |> String.replace("<", "&lt;")
              |> String.replace(">", "&gt;")

            {:error, _} ->
              "[Error reading file]"
          end

        {:error, reason} ->
          "[Access denied: #{reason}]"
      end
    end
  end
end

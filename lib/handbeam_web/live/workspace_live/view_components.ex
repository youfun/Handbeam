defmodule HandbeamWeb.WorkspaceLive.ViewComponents do
  @moduledoc false

  use HandbeamWeb, :html

  alias HandbeamWeb.WorkspaceLive.Approval
  alias HandbeamWeb.WorkspaceLive.Composer
  alias HandbeamWeb.WorkspaceLive.ConversationSwitching
  alias HandbeamWeb.WorkspaceLive.ModelSelection
  alias Handbeam.TranscriptEntry

  defdelegate model_option_label(model, models \\ []), to: ModelSelection
  defdelegate models_by_provider(models), to: ModelSelection
  defdelegate provider_display_name(provider_id), to: ModelSelection
  defdelegate model_empty_message(workspace_root), to: ModelSelection

  defdelegate archived_conversations(workspaces, conversations_by_workspace),
    to: ConversationSwitching

  defdelegate free_conversations(conversations_by_workspace), to: ConversationSwitching

  defdelegate workspace_conversations(conversations_by_workspace, ws_id, workspaces),
    to: ConversationSwitching

  defdelegate attachment_url(attachment), to: Composer
  defdelegate attachment_filename(attachment), to: Composer
  defdelegate image_attachment?(attachment), to: Composer
  defdelegate approval_action_requests(pending), to: Approval, as: :action_requests
  defdelegate format_arguments(arguments), to: Approval
  defdelegate status_dot_class(status), to: HandbeamWeb.WorkspaceHelper
  defdelegate tool_status_icon(status), to: HandbeamWeb.WorkspaceHelper
  defdelegate tool_status_class(status), to: HandbeamWeb.WorkspaceHelper
  defdelegate tool_border_class(status), to: HandbeamWeb.WorkspaceHelper
  defdelegate render_tool_status(status), to: HandbeamWeb.WorkspaceHelper
  defdelegate tool_entry_count(entries), to: HandbeamWeb.WorkspaceHelper
  defdelegate timeline_summary(entries), to: HandbeamWeb.WorkspaceHelper
  defdelegate user_message_nav_items(entries), to: HandbeamWeb.WorkspaceHelper
  defdelegate format_duration(ms), to: HandbeamWeb.WorkspaceHelper
  defdelegate format_bytes(bytes), to: HandbeamWeb.WorkspaceHelper
  defdelegate format_tokens(tokens), to: HandbeamWeb.WorkspaceHelper
  defdelegate format_cache_hit_rate(status), to: HandbeamWeb.WorkspaceHelper
  defdelegate diff_prefix(type), to: HandbeamWeb.WorkspaceHelper
  defdelegate file_value(file, key, default), to: HandbeamWeb.WorkspaceHelper
  defdelegate archived_stream_count(entries), to: HandbeamWeb.WorkspaceHelper
  defdelegate browser_install_prompt(entry), to: HandbeamWeb.WorkspaceHelper
  defdelegate preview_card(entry), to: HandbeamWeb.WorkspaceHelper
  defdelegate browser_takeover_prompt(entry), to: HandbeamWeb.WorkspaceHelper

  defdelegate render_file_preview(path, workspace_root \\ Handbeam.Workspace.root()),
    to: HandbeamWeb.WorkspaceHelper

  defdelegate tool_entry_name(entry), to: TranscriptEntry, as: :tool_name
  defdelegate tool_entry_status(entry), to: TranscriptEntry, as: :tool_status
  defdelegate tool_entry_duration(entry), to: TranscriptEntry, as: :duration_ms
  defdelegate tool_entry_error(entry), to: TranscriptEntry, as: :error
  defdelegate tool_entry_input_summary(entry), to: TranscriptEntry, as: :input_summary

  def workspace_group_collapsed?(collapsed, id) when is_struct(collapsed, MapSet) do
    MapSet.member?(collapsed, to_string(id))
  end

  def workspace_group_collapsed?(_, _), do: false

  def active_conversation_count(conversations_by_workspace, ws_id, workspaces) do
    conversations_by_workspace
    |> workspace_conversations(ws_id, workspaces)
    |> length()
  end

  def free_conversation_count(conversations_by_workspace) do
    conversations_by_workspace |> free_conversations() |> length()
  end

  def scoped_conversation_count(conversations_by_workspace, :free, _ws_id, _workspaces) do
    free_conversation_count(conversations_by_workspace)
  end

  def scoped_conversation_count(conversations_by_workspace, _scope, ws_id, workspaces) do
    active_conversation_count(conversations_by_workspace, ws_id, workspaces)
  end

  def has_cache_tokens?(%{cache_read_tokens: read, cache_write_tokens: write})
      when is_number(read) and is_number(write) do
    read > 0 or write > 0
  end

  def has_cache_tokens?(_), do: false

  def reasoning_label(level) do
    case level do
      "off" -> gettext("Off")
      "minimal" -> gettext("Minimal")
      "low" -> gettext("Low")
      "medium" -> gettext("Medium")
      "high" -> gettext("High")
      "xhigh" -> gettext("X-High")
      _ -> level
    end
  end

  def relative_time(conv) do
    case Map.get(conv, :updated_at) || Map.get(conv, "updated_at") || Map.get(conv, :created_at) ||
           Map.get(conv, "created_at") do
      nil ->
        ""

      dt_str ->
        case DateTime.from_iso8601(dt_str) do
          {:ok, dt, _} ->
            diff = DateTime.diff(DateTime.utc_now(), dt, :second)

            cond do
              diff < 60 -> "刚刚"
              diff < 3600 -> "#{div(diff, 60)}分钟前"
              diff < 86400 -> "#{div(diff, 3600)}小时前"
              true -> dt_str |> String.slice(0, 10)
            end

          _ ->
            ""
        end
    end
  end

  def any_sheet_open?(show_workspace, show_model, show_reasoning, show_settings) do
    show_workspace or show_model or show_reasoning or show_settings
  end

  def settings_href(workspace_id, conversation_id) do
    query = %{}
    query = if workspace_id, do: Map.put(query, :workspace_id, workspace_id), else: query
    query = if conversation_id, do: Map.put(query, :conversation_id, conversation_id), else: query
    ~p"/settings?#{query}"
  end

  def permission_label(:auto), do: "完整存取"

  def permission_label(:prompt), do: "安全模式"

  def permission_label(:deny), do: "只读"
  def permission_label(:auto_review), do: "智能审批"
  def permission_label(_), do: "完整存取"

  def permission_title(:auto_review), do: gettext("只自动复审本来要问的操作，不扩大权限。")
  def permission_title(mode), do: "#{gettext("当前权限:")}#{permission_label(mode)}"

  def assistant_message_final?(entry, running, current_assistant_entry_id) do
    HandbeamWeb.WorkspaceLive.RuntimeProjection.assistant_final?(
      entry,
      running,
      current_assistant_entry_id
    )
  end

  def assistant_message_streaming?(entry, running, current_assistant_entry_id) do
    running && Map.get(entry, "id") == current_assistant_entry_id &&
      !truthy?(Map.get(entry, "final"))
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]
end

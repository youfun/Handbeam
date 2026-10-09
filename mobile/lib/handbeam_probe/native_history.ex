defmodule HandbeamProbe.NativeHistory do
  @moduledoc "Cross-workspace conversation history: pinned, free chats, then each workspace."
  use Gettext, backend: HandbeamProbe.Gettext
  import HandbeamProbe.NativeUI

  alias Handbeam.ConversationStore

  @folder_mark "▣"

  def load(now \\ DateTime.utc_now()) do
    project(Handbeam.ConversationStore.list(), Handbeam.WorkspaceStore.list(), now)
  end

  def project(conversations, workspaces, _now) do
    workspace_map = Map.new(workspaces, &{&1["id"], &1})

    listed =
      conversations
      |> Enum.filter(&listed?(&1, workspace_map))
      |> Enum.sort_by(&{timestamp(&1), &1["id"] || ""}, :desc)

    {pinned, unpinned} = Enum.split_with(listed, &ConversationStore.pinned_conversation?/1)
    {free, rest} = Enum.split_with(unpinned, &ConversationStore.free?/1)

    %{
      pinned: Enum.sort_by(pinned, &{&1["pinned_at"] || "", &1["id"] || ""}, :desc),
      free: free,
      workspaces: workspace_groups(workspaces, rest)
    }
  end

  def render(history, opts) when is_map(opts) do
    ctx = %{
      selected_id: Map.get(opts, :selected_id),
      collapsed: Map.get(opts, :collapsed, MapSet.new()),
      running_ids: Map.get(opts, :running_ids, MapSet.new()),
      menu_id: Map.get(opts, :menu_id),
      rename: Map.get(opts, :rename)
    }

    pinned = Map.get(history, :pinned, [])
    free = Map.get(history, :free, [])
    workspaces = Map.get(history, :workspaces, [])

    pinned_nodes =
      if pinned == [] do
        []
      else
        group("pinned", gettext("已置顶"), pinned, ctx, nil)
      end

    free_nodes = group("free", gettext("对话"), free, ctx, icon("add", {:new_free_chat}))

    workspace_nodes =
      Enum.flat_map(workspaces, fn %{workspace: workspace, conversations: conversations} ->
        group(
          workspace["id"],
          "#{@folder_mark} #{workspace["name"] || workspace["id"]}",
          conversations,
          ctx,
          icon("add", {:new_workspace_conversation, workspace["id"]})
        )
      end)

    pinned_nodes ++ free_nodes ++ workspace_nodes
  end

  defp workspace_groups(workspaces, conversations) do
    Enum.map(workspaces, fn workspace ->
      %{
        workspace: workspace,
        conversations: Enum.filter(conversations, &(&1["workspace_id"] == workspace["id"]))
      }
    end)
  end

  defp listed?(conversation, workspaces) do
    conversation["archived_at"] in [nil, ""] and
      (ConversationStore.free?(conversation) or
         Map.has_key?(workspaces, conversation["workspace_id"]))
  end

  defp group(id, label, conversations, ctx, action) do
    header(id, label, length(conversations), ctx.collapsed, action) ++
      if(MapSet.member?(ctx.collapsed, id), do: [], else: conversation_rows(conversations, ctx))
  end

  defp header(id, label, count, collapsed, action) do
    chevron = if(MapSet.member?(collapsed, id), do: "›", else: "⌄")

    [
      row(
        [
          button(label, {:toggle_history_group, id},
            id: "history-group-#{id}",
            fill_width: false,
            background: color(:surface),
            text_color: color(:muted),
            text_size: 12,
            padding: 4
          ),
          node(:box, weight: 1, height: 1, background: color(:separator)),
          action,
          button("#{count} #{chevron}", {:toggle_history_group, id},
            id: "history-group-toggle-#{id}",
            fill_width: false,
            background: color(:surface),
            text_color: color(:muted),
            text_size: 12,
            padding: 4
          )
        ],
        padding_top: 12,
        padding_bottom: 4
      )
    ]
  end

  defp conversation_rows(conversations, ctx) do
    Enum.flat_map(conversations, fn conversation ->
      conversation_nodes(conversation,
        selected?: conversation["id"] == ctx.selected_id,
        running?: MapSet.member?(ctx.running_ids, conversation["id"]),
        menu_open?: ctx.menu_id != nil and conversation["id"] == ctx.menu_id,
        rename: ctx.rename
      )
    end)
  end

  defp conversation_nodes(conversation, opts) do
    nodes =
      if Code.ensure_loaded?(HandbeamProbe.NativeConversationRow) do
        apply(HandbeamProbe.NativeConversationRow, :nodes, [conversation, opts])
      else
        title_button(conversation, opts)
      end

    nodes |> List.wrap() |> Enum.reject(&is_nil/1)
  end

  defp title_button(conversation, opts) do
    selected? = Keyword.get(opts, :selected?, false)

    button(
      conversation["title"] || gettext("New conversation"),
      {:conversation, conversation["id"]},
      fill_width: true,
      background: if(selected?, do: color(:control), else: color(:surface)),
      text_size: 13,
      max_lines: 1,
      ellipsize: "end"
    )
  end

  defp timestamp(conversation) do
    case DateTime.from_iso8601(conversation["updated_at"] || conversation["created_at"] || "") do
      {:ok, datetime, _} -> DateTime.to_unix(datetime)
      _ -> 0
    end
  end
end

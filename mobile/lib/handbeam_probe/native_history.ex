defmodule HandbeamProbe.NativeHistory do
  @moduledoc "Cross-workspace conversation history, grouped by recency and workspace."
  use Gettext, backend: HandbeamProbe.Gettext
  import HandbeamProbe.NativeUI

  alias Handbeam.ConversationStore

  @recent_seconds 72 * 60 * 60
  @free_group_id "free"

  def load(now \\ DateTime.utc_now()) do
    project(Handbeam.ConversationStore.list(), Handbeam.WorkspaceStore.list(), now)
  end

  def project(conversations, workspaces, now) do
    workspace_map = Map.new(workspaces, &{&1["id"], &1})
    cutoff = DateTime.to_unix(now) - @recent_seconds

    {recent, inactive} =
      conversations
      |> Enum.filter(&listed?(&1, workspace_map))
      |> Enum.sort_by(&{timestamp(&1), &1["id"]}, :desc)
      |> Enum.split_with(&(timestamp(&1) >= cutoff))

    %{
      recent: groups(recent, workspace_map, include_free: true),
      inactive: groups(inactive, workspace_map, include_free: false),
      inactive_count: length(inactive)
    }
  end

  def render(history, expanded?, selected_id) do
    render_groups(history.recent, selected_id) ++
      if(history.inactive_count > 0,
        do:
          [
            button(
              gettext("Inactive over 72 hours") <>
                " (#{history.inactive_count}) " <>
                if(expanded?, do: "⌄", else: "›"),
              :toggle_inactive_history,
              fill_width: true,
              background: color(:surface),
              text_color: color(:muted),
              text_size: 12
            )
          ] ++ if(expanded?, do: render_groups(history.inactive, selected_id), else: []),
        else: []
      ) ++
      if(history.recent == [] and history.inactive_count == 0,
        do: [text(gettext("No conversations yet"), padding_top: 24)],
        else: []
      )
  end

  defp listed?(conversation, workspaces) do
    conversation["archived_at"] in [nil, ""] and
      (ConversationStore.free?(conversation) or
         Map.has_key?(workspaces, conversation["workspace_id"]))
  end

  defp groups(conversations, workspaces, opts) do
    grouped =
      conversations
      |> Enum.group_by(&group_id/1)
      |> then(fn groups ->
        if Keyword.get(opts, :include_free, false),
          do: Map.put_new(groups, @free_group_id, []),
          else: groups
      end)

    grouped
    |> Enum.map(fn {id, items} ->
      %{workspace: group_workspace(id, workspaces), conversations: items}
    end)
    |> Enum.sort_by(&group_sort_key/1, :desc)
  end

  # Free chats stay at the top so the new-chat action is visible with an empty list.
  defp group_sort_key(%{workspace: %{"free" => true}} = group),
    do: {1, group_sort_time(group), ""}

  defp group_sort_key(group), do: {0, group_sort_time(group), group.workspace["id"]}

  defp group_sort_time(%{conversations: [first | _]}), do: timestamp(first)
  defp group_sort_time(_group), do: 0

  defp group_id(conversation) do
    if ConversationStore.free?(conversation),
      do: @free_group_id,
      else: conversation["workspace_id"]
  end

  defp group_workspace(@free_group_id, _workspaces) do
    %{"id" => @free_group_id, "name" => gettext("Chats"), "free" => true}
  end

  defp group_workspace(id, workspaces), do: workspaces[id]

  defp render_groups(groups, selected_id) do
    Enum.flat_map(groups, fn group ->
      [
        row(
          [
            text(group.workspace["name"], text_size: 12, text_color: color(:muted)),
            node(:box, weight: 1, height: 1, background: color(:separator)),
            if(group.workspace["free"], do: icon("add", :new_free_chat))
          ],
          padding_top: 12,
          padding_bottom: 4
        )
      ] ++
        Enum.map(group.conversations, fn c ->
          button(c["title"] || gettext("New conversation"), {:conversation, c["id"]},
            fill_width: true,
            background: if(c["id"] == selected_id, do: color(:control), else: color(:surface)),
            text_size: 13,
            max_lines: 1,
            ellipsize: "end"
          )
        end)
    end)
  end

  defp timestamp(c) do
    case DateTime.from_iso8601(c["updated_at"] || c["created_at"] || "") do
      {:ok, datetime, _} -> DateTime.to_unix(datetime)
      _ -> 0
    end
  end
end

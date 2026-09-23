defmodule HandbeamProbe.NativeHistory do
  @moduledoc "Cross-workspace conversation history, grouped by recency and workspace."
  use Gettext, backend: HandbeamProbe.Gettext
  import HandbeamProbe.NativeUI

  @recent_seconds 72 * 60 * 60

  def load(now \\ DateTime.utc_now()) do
    project(Handbeam.ConversationStore.list(), Handbeam.WorkspaceStore.list(), now)
  end

  def project(conversations, workspaces, now) do
    workspace_map = Map.new(workspaces, &{&1["id"], &1})
    cutoff = DateTime.to_unix(now) - @recent_seconds

    {recent, inactive} =
      conversations
      |> Enum.filter(fn c ->
        c["archived_at"] in [nil, ""] and Map.has_key?(workspace_map, c["workspace_id"])
      end)
      |> Enum.sort_by(&{timestamp(&1), &1["id"]}, :desc)
      |> Enum.split_with(&(timestamp(&1) >= cutoff))

    %{
      recent: groups(recent, workspace_map),
      inactive: groups(inactive, workspace_map),
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

  defp groups(conversations, workspaces) do
    conversations
    |> Enum.group_by(& &1["workspace_id"])
    |> Enum.map(fn {id, items} -> %{workspace: workspaces[id], conversations: items} end)
    |> Enum.sort_by(&{timestamp(hd(&1.conversations)), &1.workspace["id"]}, :desc)
  end

  defp render_groups(groups, selected_id) do
    Enum.flat_map(groups, fn group ->
      [
        row(
          [
            text(group.workspace["name"], text_size: 12, text_color: color(:muted)),
            node(:box, weight: 1, height: 1, background: color(:separator))
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

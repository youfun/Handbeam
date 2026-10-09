defmodule HandbeamProbe.NativeConversationRow do
  @moduledoc """
  One conversation row for the native history list.

  History render should pass the pending rename assign on every row:

      NativeConversationRow.nodes(conversation,
        selected?: conversation["id"] == selected_id,
        running?: MapSet.member?(assigns.running_conversation_ids, conversation["id"]),
        menu_open?: assigns.conversation_menu_id == conversation["id"],
        rename: assigns.rename_conversation
      )

  The rename field is shown only when `opts[:rename]` is a map whose id
  equals this conversation. Selection is a thin mark and title color.
  A running row shows a short `●` mark. The menu lists pin, rename, and archive.
  """

  use Gettext, backend: HandbeamProbe.Gettext
  import HandbeamProbe.NativeUI

  alias Handbeam.ConversationStore

  @doc """
  Mob nodes for `conversation`.

  `opts` accepts `:selected?`, `:running?`, `:menu_open?`, and `:rename`
  (`nil` or `%{id, title, error}`).
  """
  @spec nodes(map(), keyword()) :: [map()]
  def nodes(conversation, opts \\ []) when is_map(conversation) and is_list(opts) do
    id = conversation["id"]
    selected? = Keyword.get(opts, :selected?, false)
    running? = Keyword.get(opts, :running?, false)
    menu_open? = Keyword.get(opts, :menu_open?, false)

    [
      node(:column, [fill_width: true, background: color(:surface)], [
        row(
          [
            selected_mark(selected?),
            running_mark(running?),
            title_node(id, conversation_title(conversation), selected?),
            menu_button(id)
          ],
          background: color(:surface),
          padding_top: 2,
          padding_bottom: 2
        )
        | menu_nodes(conversation, menu_open?) ++
            rename_nodes(conversation, Keyword.get(opts, :rename))
      ])
    ]
  end

  defp conversation_title(conversation) do
    case conversation["title"] do
      title when is_binary(title) and title != "" -> title
      _ -> gettext("New conversation")
    end
  end

  defp selected_mark(false), do: nil

  defp selected_mark(true) do
    text("▍", text_size: 13, text_color: color(:ink), padding_right: 4)
  end

  defp running_mark(false), do: nil

  defp running_mark(true) do
    text("●",
      id: "conversation-running",
      text_size: 11,
      text_color: color(:added),
      padding_right: 4
    )
  end

  defp title_node(id, title, selected?) do
    text(title,
      id: "conversation-title-#{id}",
      on_tap: {self(), {:conversation, id}},
      text_size: 13,
      text_color: if(selected?, do: color(:ink), else: color(:muted)),
      max_lines: 1,
      ellipsize: "end",
      weight: 1,
      fill_width: true
    )
  end

  defp menu_button(id) do
    text("⋯",
      id: "conversation-menu-#{id}",
      on_tap: {self(), {:toggle_conversation_menu, id}},
      text_size: 16,
      text_color: color(:muted),
      padding: 6
    )
  end

  defp menu_nodes(_conversation, false), do: []

  defp menu_nodes(conversation, true) do
    id = conversation["id"]

    pin_label =
      if ConversationStore.pinned_conversation?(conversation),
        do: gettext("Unpin"),
        else: gettext("Pin")

    [
      action(pin_label, {:toggle_pin_conversation, id}, "conversation-action-pin-#{id}"),
      action(gettext("Rename"), {:rename_conversation, id}, "conversation-action-rename-#{id}"),
      action(gettext("Archive"), {:archive_conversation, id}, "conversation-action-archive-#{id}")
    ]
  end

  defp action(label, tag, id) do
    text(label,
      id: id,
      on_tap: {self(), tag},
      text_size: 13,
      text_color: color(:ink),
      padding: 8,
      background: color(:card)
    )
  end

  defp rename_nodes(%{"id" => id}, rename) when is_map(rename) do
    if rename_id(rename) == id do
      title = rename_title(rename)

      [
        field(gettext("Rename"), title, {:rename_conversation_title, id}),
        rename_error(rename_error_text(rename)),
        action(
          gettext("Rename"),
          {:confirm_rename_conversation, title},
          "conversation-rename-save-#{id}"
        ),
        action(gettext("Cancel"), :cancel_rename_conversation, "conversation-rename-cancel-#{id}")
      ]
    else
      []
    end
  end

  defp rename_nodes(_, _), do: []

  defp rename_id(%{id: id}), do: id
  defp rename_id(%{"id" => id}), do: id
  defp rename_id(_), do: nil

  defp rename_title(%{title: title}) when is_binary(title), do: title
  defp rename_title(%{"title" => title}) when is_binary(title), do: title
  defp rename_title(_), do: ""

  defp rename_error_text(%{error: error}) when is_binary(error) and error != "", do: error
  defp rename_error_text(%{"error" => error}) when is_binary(error) and error != "", do: error
  defp rename_error_text(_), do: nil

  defp rename_error(nil), do: nil

  defp rename_error(message),
    do: text(message, text_color: color(:danger), text_size: 12, padding_bottom: 4)
end

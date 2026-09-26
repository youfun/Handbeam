defmodule HandbeamProbe.NativeTimeline do
  @moduledoc "Native rendering of the shared Work transcript projection."
  use Gettext, backend: HandbeamProbe.Gettext
  import HandbeamProbe.NativeUI
  alias HandbeamProbe.Bridge.Payload
  alias HandbeamProbe.{NativeLocalImage, WorkTimeline}
  alias HandbeamWeb.WorkspaceHelper

  def project(chat, groups, segments, outputs) do
    entries = if chat, do: chat.entries, else: []

    entries =
      Enum.map(entries, fn entry ->
        type =
          case entry["role"] do
            "user" -> "user_msg"
            "assistant" -> "assistant_msg"
            "tool" -> "tool"
            _ -> "system_msg"
          end

        Map.put_new(entry, "content_type", type)
      end)

    streaming =
      if chat && chat.stream != "" do
        [
          %{
            "id" => "stream-text",
            "content_type" => "assistant_msg",
            "role" => "assistant",
            "content" => chat.stream,
            "streaming" => true
          }
        ]
      else
        []
      end

    WorkTimeline.project(entries ++ streaming, groups, segments, outputs)
  end

  def render_sent_card(_chat, open) when open in [nil, %{}], do: nil

  def render_sent_card(chat, %{message_id: message_id, attachment_id: attachment_id}) do
    entry = Enum.find(List.wrap(chat && chat.entries), &(&1["id"] == message_id))
    attachments = List.wrap(entry && entry["attachments"])
    att = Enum.find(attachments, &(NativeLocalImage.att_id(&1) == attachment_id))

    if att && NativeLocalImage.image_attachment?(att) do
      name = NativeLocalImage.att_name(att)
      type = NativeLocalImage.mime(att)
      src = upload_src(chat, att)

      node(
        :column,
        [
          fill_width: true,
          background: color(:card),
          border_color: color(:border),
          border_width: 1,
          corner_radius: 12,
          padding: 10,
          padding_bottom: 8
        ],
        [
          row([
            text(name, weight: 1, text_size: 13),
            text(type, text_size: 11, text_color: color(:hint))
          ]),
          NativeLocalImage.card_image(src, name, upload_only: true),
          button(gettext("Close"), :close_sent_image, text_size: 11, padding: 6)
        ]
      )
    end
  end

  def render_sent_card(_, _), do: nil

  def render(chat, expanded) when is_struct(expanded, MapSet) do
    tool_ids =
      (chat[:entries] || [])
      |> Enum.filter(fn entry ->
        entry["content_type"] == "tool" or entry["role"] == "tool"
      end)
      |> Enum.map(& &1["id"])

    groups =
      tool_ids
      |> Map.new(&{&1, true})
      |> Map.merge(Map.new(expanded, &{&1, true}))

    render(chat, groups, %{}, %{})
  end

  def render(chat, groups, segments, outputs) do
    project(chat, groups, segments, outputs)
    |> Enum.flat_map(fn entry ->
      [
        boundary(entry),
        if(!entry["work_hidden"], do: entry(entry, chat)),
        tool_actions(entry, chat)
      ]
    end)
    |> Kernel.++([
      if(chat && chat.running,
        do:
          text(
            if(chat.pending_approval,
              do: gettext("Waiting for approval…"),
              else: if(chat.thinking, do: gettext("Thinking…"), else: gettext("Generating…"))
            ),
            id: "stream-status",
            text_size: 12,
            text_color: color(:hint),
            padding_top: 8
          )
      )
    ])
    |> Enum.reject(&is_nil/1)
  end

  defp boundary(%{"work_segment_first" => true} = entry) do
    node(:column, [fill_width: true, padding_top: 8, padding_bottom: 8], [
      row([
        node(:box, weight: 1, height: 1, background: color(:separator)),
        button(
          if(entry["work_segment_open"],
            do: gettext("Hide Work") <> " ⌄",
            else: gettext("Show Work") <> " ›"
          ),
          {:toggle_work_segment, entry["work_segment_id"]},
          background: color(:surface),
          text_color: color(:hint),
          text_size: 12
        ),
        node(:box, weight: 1, height: 1, background: color(:separator))
      ]),
      if(entry["work_hidden"] && entry["work_boundary_summary"],
        do: summary(entry["work_boundary_summary"], false)
      )
    ])
  end

  defp boundary(_), do: nil

  defp entry(%{"content_type" => "tool"} = entry, chat) do
    entry = Map.put(entry, "workspace_path", chat_workspace_path(chat))

    node(:column, [fill_width: true, padding_bottom: 6], [
      if(entry["work_group_first"], do: summary(entry, true)),
      if(!entry["work_collapsed"], do: tool_output(entry)),
      if(!entry["work_collapsed"], do: delivery_actions(entry, chat))
    ])
  end

  defp entry(entry, chat) do
    role = Payload.first(entry, ["role", "message_type"]) || "system"
    body = Payload.first(entry, ["content", "error"]) || ""

    if role == "user" do
      attachments = List.wrap(entry["attachments"])
      {images, others} = Enum.split_with(attachments, &NativeLocalImage.image_attachment?/1)
      images = Enum.take(images, 4)

      names =
        others
        |> Enum.map(&(&1["filename"] || &1["display_name"]))
        |> Enum.reject(&is_nil/1)

      attachment_line =
        if names == [],
          do: nil,
          else: text(Enum.join(names, " · "), text_size: 11, text_color: color(:hint))

      row(
        [
          node(:column, weight: 1),
          node(:column, [weight: 3], [
            sent_thumbs(chat, entry["id"], images),
            if(body != "",
              do:
                node(:box, [fill_width: true, align: "top_trailing"], [
                  text(body,
                    selectable: true,
                    background: color(:bubble),
                    corner_radius: 18,
                    padding: 10
                  )
                ])
            ),
            if(attachment_line,
              do: node(:box, [fill_width: true, align: "top_trailing"], [attachment_line])
            ),
            pending_status_row(entry, chat)
          ])
        ],
        nav_user_id: entry["id"],
        nav_user_summary:
          body |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 80)
      )
    else
      node(:column, [fill_width: true, padding_top: 12, padding_bottom: 20], [
        if(role != "assistant",
          do: text(gettext("System"), text_size: 11, text_color: color(:hint))
        ),
        text(body,
          id: entry["id"],
          selectable: true,
          markdown: role == "assistant",
          markdown_streaming: entry["streaming"] == true
        )
      ])
    end
  end

  defp summary(entry, interactive?) when is_map(entry) do
    label = entry["work_summary"]
    props = [fill_width: true, padding_top: 8, padding_bottom: 8, align: "baseline"]

    props =
      if interactive?,
        do:
          props ++
            [
              on_tap: {self(), {:toggle_tool_work, entry["work_group_id"]}},
              id: inspect({:toggle_tool_work, entry["work_group_id"]})
            ],
        else: props

    row(
      [
        text(label, text_size: 12, text_color: color(:muted), weight: 1),
        if(entry["work_edit"],
          do: text("+#{entry["work_added"]}", text_size: 12, text_color: color(:added))
        ),
        if(entry["work_edit"],
          do: text(" −#{entry["work_removed"]}", text_size: 12, text_color: color(:danger))
        ),
        if(entry["work_failed"] > 0,
          do:
            text(gettext("%{count} failed", count: entry["work_failed"]),
              text_size: 12,
              text_color: color(:danger)
            )
        ),
        if(entry["work_cancelled"] > 0,
          do:
            text(gettext("%{count} cancelled", count: entry["work_cancelled"]),
              text_size: 12,
              text_color: color(:muted)
            )
        ),
        if(interactive?,
          do: text(if(entry["work_collapsed"], do: " ›", else: " ⌄"), text_size: 12)
        )
      ],
      props
    )
  end

  defp summary(label, _interactive?) when is_binary(label) do
    text(label, text_size: 12, text_color: color(:muted))
  end

  defp tool_output(entry) do
    output = WorkTimeline.output(entry)

    node(:column, [fill_width: true, padding_left: 8], [
      button(
        "#{WorkTimeline.name(entry)} · #{WorkTimeline.input_label(entry)} · #{WorkTimeline.status(entry)}",
        {:toggle_tool_output, entry["id"]},
        fill_width: true,
        max_lines: 1,
        ellipsize: "end",
        text_size: 12,
        background: color(:surface),
        padding: 6
      ),
      if(entry["tool_output_open"],
        do:
          node(:scroll, [id: "tool-output-#{entry["id"]}", fill_width: true, max_height: 180], [
            text(if(output == "", do: gettext("No output yet"), else: output),
              text_size: 12,
              selectable: true
            )
          ])
      )
    ])
  end

  defp tool_actions(%{"content_type" => "tool"} = entry, chat) do
    preview = WorkspaceHelper.preview_card(entry)
    takeover = WorkspaceHelper.browser_takeover_prompt(entry)

    cond do
      preview ->
        button(
          gettext("Open preview · %{title}", title: preview.title),
          {:tool_action, chat.conversation["id"], :preview, preview.preview_id},
          fill_width: true
        )

      takeover && is_binary(takeover.session_id) ->
        button(
          gettext("Take over browser · %{reason}", reason: takeover.reason),
          {:tool_action, chat.conversation["id"], :browser, takeover.session_id},
          fill_width: true
        )

      true ->
        nil
    end
  end

  defp tool_actions(_, _), do: nil

  defp pending_status_row(entry, chat) do
    pending = chat && Map.get(chat, :pending)
    item = is_map(pending) && Map.get(pending, entry["id"])
    if item, do: pending_status_controls(entry["id"], item, chat)
  end

  defp pending_status_controls(id, %{status: :undelivered}, _chat) do
    row(
      [
        text(gettext("Not delivered"), text_size: 12, text_color: color(:hint), weight: 1),
        button(gettext("Resend"), {:resend_pending, id}, text_size: 11, padding: 6)
      ],
      padding_top: 4
    )
  end

  defp pending_status_controls(id, %{status: :queued, deliver_as: deliver_as}, chat) do
    label =
      cond do
        chat && chat.pending_approval ->
          gettext("Inserts after approval")

        deliver_as == :follow_up ->
          gettext("Queued · when this run finishes")

        true ->
          gettext("Waiting to insert · next step")
      end

    row(
      [
        text(label, text_size: 12, text_color: color(:hint), weight: 1),
        button(gettext("Undo"), {:cancel_pending, id}, text_size: 11, padding: 6)
      ],
      padding_top: 4
    )
  end

  defp pending_status_controls(_, _, _), do: nil

  defp sent_thumbs(_chat, _message_id, []), do: nil

  defp sent_thumbs(chat, message_id, images) do
    thumbs =
      Enum.map(images, fn att ->
        id = NativeLocalImage.att_id(att)
        name = NativeLocalImage.att_name(att)
        src = upload_src(chat, att)

        NativeLocalImage.thumb(src, name,
          upload_only: true,
          on_tap: {self(), {:open_sent_image, message_id, id}},
          id: "sent-thumb-#{message_id}-#{id}"
        )
      end)

    node(:box, [fill_width: true, align: "top_trailing", padding_bottom: 6], [
      node(:row, [align: "center"], thumbs)
    ])
  end

  # Resolved when entries entered chat state (NativeLocalImage.resolve_entries/3);
  # render never stats the filesystem.
  defp upload_src(_chat, att), do: NativeLocalImage.sent_src(att)

  defp chat_workspace_path(%{workspace_path: path}) when is_binary(path), do: path
  defp chat_workspace_path(_), do: nil

  defp chat_workspace_id(%{workspace_id: id}) when is_binary(id), do: id
  defp chat_workspace_id(_), do: nil

  defp chat_conversation_id(%{conversation: %{"id" => id}}) when is_binary(id), do: id
  defp chat_conversation_id(_), do: nil

  defp delivery_actions(entry, chat) do
    workspace = chat_workspace_path(chat)

    case HandbeamProbe.NativeArtifactDelivery.timeline_target(entry, workspace) do
      {:url, url} ->
        actions_row([
          button(gettext("Open in system browser"), {:delivery, :open_url, url},
            text_size: 11,
            padding: 6
          )
        ])

      {:file, path} ->
        spec =
          HandbeamProbe.NativeWorkspaceOpen.spec(
            :timeline,
            path,
            chat_workspace_id(chat),
            chat_conversation_id(chat)
          )

        actions_row([
          button(gettext("Open"), {:workspace_open, :view, spec}, text_size: 11, padding: 6),
          button(gettext("Open in another app"), {:delivery, :open_file, spec},
            text_size: 11,
            padding: 6
          ),
          button(gettext("Share file"), {:delivery, :share_file, spec}, text_size: 11, padding: 6)
        ])

      _ ->
        nil
    end
  end
end

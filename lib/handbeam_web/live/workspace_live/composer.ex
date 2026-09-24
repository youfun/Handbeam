defmodule HandbeamWeb.WorkspaceLive.Composer do
  @moduledoc false

  use Gettext, backend: HandbeamWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [consume_uploaded_entries: 3, stream: 4]

  alias HandbeamWeb.WorkspaceLive.Skills

  def upload_error(:too_large), do: "File too large (max 5MB)"
  def upload_error(:not_accepted), do: "Unsupported file type (images only)"
  def upload_error(:too_many_files), do: "Too many files (max 4)"
  def upload_error(other), do: to_string(other)

  def remove_attachment(socket, id) do
    attachments = Enum.reject(socket.assigns.pending_attachments, &((&1[:id] || &1["id"]) == id))
    assign(socket, :pending_attachments, attachments)
  end

  def has_upload_entries?(socket) do
    case socket.assigns.uploads[:images] do
      %{entries: entries} when is_list(entries) -> entries != []
      _ -> false
    end
  end

  def prepare(socket, message, workspace_path) do
    {socket, attachments} = consume_images(socket, workspace_path)

    case Handbeam.Attachments.MessageBuilder.build(
           message,
           attachments,
           build_opts(socket, workspace_path)
         ) do
      {:ok, content, persistable} ->
        persistable = merge_upload_urls(attachments, persistable)
        content = Skills.expand(content, socket.assigns.available_skills)
        {:ok, assign(socket, :pending_attachments, persistable), content, persistable}

      {:error, reason} ->
        {:error, assign(socket, :composer_error, outbound_error(reason))}
    end
  end

  def restore_draft(socket, %{content: content, attachments: attachments}) do
    socket |> restore_text(content) |> restore_attachments(attachments)
  end

  def restore_draft(socket, item) when is_map(item) do
    socket |> restore_text(item[:content]) |> restore_attachments(item[:attachments])
  end

  def restore_draft(socket, _), do: socket

  def assign_pending(socket, pending) do
    socket
    |> assign(:pending_messages, pending)
    |> stream(:timeline, socket.assigns.timeline || [], reset: true)
  end

  def drop_transcript_entry(conversation_id, id)
      when is_binary(conversation_id) and is_binary(id) do
    Handbeam.ConversationTranscriptStore.delete(conversation_id, id)
  end

  def put_message_id(%Handbeam.Agent.Message{} = message, id), do: %{message | id: id}
  def put_message_id(content, _id), do: content

  def outbound_error(:empty), do: nil
  def outbound_error(:images_not_supported), do: "Current model cannot accept images."
  def outbound_error(:too_many_attachments), do: "At most 4 attachments per message."
  def outbound_error(:image_too_large), do: "An image exceeds 5,000,000 bytes."
  def outbound_error(:text_too_large), do: "A text attachment exceeds 20 MiB."
  def outbound_error(:batch_too_large), do: "Attachments exceed the 25 MiB batch limit."
  def outbound_error(reason), do: "Attachment failed: #{inspect(reason)}"

  def resend_error(:queue_full), do: gettext("Could not resend because the queue is full.")

  def resend_error(:sealed),
    do: gettext("Could not resend because the run is no longer accepting input.")

  def resend_error(reason), do: outbound_error(reason)

  def attachment_url(%{url: url}) when is_binary(url) and url != "", do: url
  def attachment_url(%{"url" => url}) when is_binary(url) and url != "", do: url

  def attachment_url(%{data: data, mime_type: type}) when is_binary(data),
    do: "data:#{type || "image/png"};base64,#{data}"

  def attachment_url(%{"data" => data, "mime_type" => type}) when is_binary(data),
    do: "data:#{type || "image/png"};base64,#{data}"

  def attachment_url(_), do: "#"

  def attachment_filename(%{filename: filename}) when is_binary(filename), do: filename
  def attachment_filename(%{"filename" => filename}) when is_binary(filename), do: filename
  def attachment_filename(_), do: "image"

  def build_opts(socket, workspace_path) do
    if socket.assigns[:chat_scope] == :free do
      [chat_scope: :free, conversation_id: socket.assigns.current_conversation_id]
    else
      [workspace_path: workspace_path, conversation_id: socket.assigns.current_conversation_id]
    end
  end

  defp consume_images(socket, workspace_path) do
    conversation_id = socket.assigns.current_conversation_id
    free? = socket.assigns[:chat_scope] == :free
    workspace_id = socket.assigns.current_workspace_id

    new =
      consume_uploaded_entries(socket, :images, fn meta, entry ->
        if extension(entry) == "bin" do
          {:postpone, nil}
        else
          id = Ecto.UUID.generate()
          directory = upload_directory!(free?, workspace_path, conversation_id)
          filename = "#{id}.#{extension(entry)}"
          path = Path.join(directory, filename)
          File.cp!(meta.path, path)

          {:ok,
           %{
             id: id,
             kind: "image",
             mime_type: entry.client_type,
             size_bytes: entry.client_size,
             filename: entry.client_name,
             storage_path: path,
             relative_path: upload_relative(free?, path, workspace_path),
             url: upload_url(free?, conversation_id, filename, workspace_id)
           }}
        end
      end)
      |> Enum.reject(&is_nil/1)

    attachments = Enum.take(socket.assigns.pending_attachments ++ new, 4)
    {assign(socket, :pending_attachments, attachments), attachments}
  rescue
    error ->
      socket = assign(socket, :composer_error, Exception.message(error))
      {socket, socket.assigns.pending_attachments}
  end

  defp upload_directory!(true, _workspace_path, conversation_id),
    do: Handbeam.Uploads.ensure_free_upload_dir!(conversation_id)

  defp upload_directory!(false, workspace_path, conversation_id),
    do: Handbeam.Uploads.ensure_conversation_dir!(workspace_path, conversation_id)

  defp upload_relative(true, path, _workspace_path), do: Path.basename(path)
  defp upload_relative(false, path, workspace_path), do: Path.relative_to(path, workspace_path)

  defp upload_url(true, conversation_id, filename, _workspace_id),
    do: "/uploads/#{conversation_id}/#{filename}"

  defp upload_url(false, conversation_id, filename, workspace_id),
    do: "/uploads/#{conversation_id}/#{filename}?ws_id=#{workspace_id}"

  defp extension(entry) do
    case String.downcase(entry.client_type || "") do
      "image/png" -> "png"
      "image/jpeg" -> "jpg"
      "image/gif" -> "gif"
      "image/webp" -> "webp"
      _ -> "bin"
    end
  end

  defp merge_upload_urls(original, persistable) do
    by_id = Map.new(original, &{&1[:id] || &1["id"], &1})

    Enum.map(persistable, fn attachment ->
      case by_id[attachment["id"]] do
        %{url: url} -> Map.put(attachment, "url", url)
        %{"url" => url} -> Map.put(attachment, "url", url)
        _ -> attachment
      end
    end)
  end

  defp restore_text(socket, content) when is_binary(content) and content != "" do
    current = socket.assigns.input_value || ""

    value =
      if String.trim(current) == "",
        do: content,
        else: String.trim_trailing(current) <> "\n" <> content

    assign(socket, :input_value, value)
  end

  defp restore_text(socket, _), do: socket

  defp restore_attachments(socket, attachments) when is_list(attachments) and attachments != [],
    do: assign(socket, :pending_attachments, socket.assigns.pending_attachments ++ attachments)

  defp restore_attachments(socket, _), do: socket
end

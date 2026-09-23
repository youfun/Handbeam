defmodule Handbeam.Attachments.MessageBuilder do
  @moduledoc """
  Shared text + attachment inbound message construction for Web and native.
  First-turn missing or unreadable images are errors, not silent success.
  """

  alias Handbeam.Agent.Message
  alias Handbeam.Attachments
  alias Handbeam.Attachments.{Access, Imported}
  alias Handbeam.Uploads

  @spec build(String.t(), [map() | Imported.t()], keyword()) ::
          {:ok, String.t() | Message.t(), [map()]} | {:error, term()}
  def build(text, attachments, opts \\ [])
      when is_binary(text) and is_list(attachments) do
    text = String.trim(text)

    with :ok <- non_empty(text, attachments),
         :ok <- Attachments.validate_batch(attachments, opts),
         {:ok, promoted} <- promote_all(attachments, opts),
         :ok <- vision_gate(promoted, opts),
         {:ok, content} <- message_content(text, promoted, opts) do
      {:ok, content, Enum.map(promoted, &Attachments.persistable/1)}
    end
  end

  defp non_empty("", []), do: {:error, :empty}
  defp non_empty(_, _), do: :ok

  defp promote_all(attachments, opts) do
    Enum.reduce_while(attachments, {:ok, []}, fn item, {:ok, acc} ->
      case promote(item, opts) do
        {:ok, promoted} -> {:cont, {:ok, acc ++ [promoted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp promote(%Imported{} = imported, opts) do
    workspace = Keyword.fetch!(opts, :workspace_path)
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    Uploads.promote_imported(workspace, conversation_id, imported, opts)
  end

  defp promote(map, opts) when is_map(map) do
    workspace = Keyword.get(opts, :workspace_path)
    conversation_id = Keyword.get(opts, :conversation_id)
    relative = map[:relative_path] || map["relative_path"]
    storage = map[:storage_path] || map["storage_path"]
    controlled = map[:controlled_path] || map["controlled_path"]

    cond do
      is_binary(relative) and is_binary(workspace) and is_binary(conversation_id) ->
        with {:ok, path} <- Access.resolve_upload(workspace, conversation_id, relative),
             :ok <- Access.verify_canonical(path, map[:mime_type] || map["mime_type"]) do
          {:ok, promoted_map(map, path, relative)}
        end

      is_binary(controlled) ->
        imported = %Imported{
          attachment_id: map[:id] || map["id"] || map[:attachment_id] || Ecto.UUID.generate(),
          source: map[:source] || map["source"] || :picker,
          display_name: map[:filename] || map["filename"] || map[:display_name] || "attachment",
          canonical_type: map[:mime_type] || map["mime_type"] || map[:canonical_type],
          source_mime: map[:source_mime] || map["source_mime"],
          size_bytes: 0,
          controlled_path: controlled,
          state: :staged
        }

        promote(imported, opts)

      is_binary(storage) ->
        {:error, :absolute_storage_rejected}

      true ->
        {:error, :missing_attachment_path}
    end
  end

  defp promoted_map(map, path, relative) do
    {:ok, %File.Stat{size: size}} = File.lstat(path)

    %{
      id: map[:id] || map["id"],
      kind: map[:kind] || map["kind"],
      mime_type: map[:mime_type] || map["mime_type"],
      filename: map[:filename] || map["filename"] || map[:display_name],
      size_bytes: size,
      storage_path: path,
      relative_path: relative,
      source: map[:source] || map["source"] || :picker,
      url: map[:url] || map["url"]
    }
  end

  defp vision_gate(promoted, opts) do
    images? = Enum.any?(promoted, &Attachments.image?(to_string(&1.mime_type)))

    cond do
      not images? -> :ok
      Keyword.get(opts, :vision?, true) -> :ok
      true -> {:error, :images_not_supported}
    end
  end

  defp message_content(text, promoted, opts) do
    text_blocks = if text == "", do: [], else: [%{type: "text", text: text}]

    result =
      Enum.reduce_while(promoted, {:ok, [], []}, fn att, {:ok, images, notes} ->
        mime = att.mime_type
        name = att.filename
        relative = att.relative_path

        cond do
          Attachments.image?(to_string(mime)) ->
            case read_image(att, opts) do
              {:ok, data} ->
                {:cont, {:ok, images ++ [%{type: "image", mime_type: mime, data: data}], notes}}

              {:error, reason} ->
                {:halt, {:error, {:image_unavailable, name, reason}}}
            end

          Attachments.text?(to_string(mime)) ->
            {:cont, {:ok, images, notes ++ [text_file_note(name, relative)]}}

          true ->
            {:halt, {:error, :unsupported_type}}
        end
      end)

    case result do
      {:ok, image_blocks, text_notes} ->
        notes_blocks = Enum.map(text_notes, &%{type: "text", text: &1})
        blocks = text_blocks ++ notes_blocks ++ image_blocks

        cond do
          image_blocks == [] and notes_blocks == [] and text != "" -> {:ok, text}
          blocks == [] -> {:ok, text}
          true -> {:ok, %Message{role: :user, content: maybe_budget(blocks, opts)}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_image(%{relative_path: relative}, opts) when is_binary(relative) do
    workspace = Keyword.fetch!(opts, :workspace_path)
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    with {:ok, path} <- Access.resolve_upload(workspace, conversation_id, relative),
         {:ok, bin} <- Access.read_bounded(path, Attachments.max_image_bytes()) do
      {:ok, Base.encode64(bin)}
    end
  end

  defp read_image(_, _), do: {:error, :missing_file}

  defp text_file_note(name, relative) when is_binary(relative),
    do: "Attached text file #{name} at #{relative}. Read it with the read tool."

  defp text_file_note(name, _), do: "Attached text file #{name}."

  defp maybe_budget(blocks, opts) do
    max_images = Keyword.get(opts, :max_history_images, Attachments.max_count())
    {kept, dropped} = take_images(blocks, max_images)

    if dropped == [] do
      kept
    else
      kept ++
        [
          %{
            type: "text",
            text: "Some image attachments exceeded the history budget and were not inlined."
          }
        ]
    end
  end

  defp take_images(blocks, max) do
    Enum.reduce(blocks, {[], []}, fn
      %{type: "image"} = block, {kept, dropped} ->
        image_count = Enum.count(kept, &(&1.type == "image"))

        if image_count < max,
          do: {kept ++ [block], dropped},
          else: {kept, dropped ++ [block]}

      block, {kept, dropped} ->
        {kept ++ [block], dropped}
    end)
  end
end

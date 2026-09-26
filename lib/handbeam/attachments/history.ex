defmodule Handbeam.Attachments.History do
  @moduledoc """
  Rebuild provider messages from persisted attachment references.
  Missing or invalid images become explicit text, never silent text-only history.
  """

  alias Handbeam.Agent.Message
  alias Handbeam.Attachments
  alias Handbeam.Attachments.Access

  @spec to_messages(map(), String.t() | nil, String.t() | nil) :: [Message.t()]
  def to_messages(entry, workspace_path, conversation_id \\ nil)

  def to_messages(entry, workspace_path, conversation_id) when is_map(entry) do
    role = entry["role"]
    text = entry["content"]
    attachments = List.wrap(entry["attachments"])
    conversation_id = conversation_id || entry["conversation_id"]

    cond do
      role == "user" and attachments != [] ->
        case rebuild_user(text, attachments, workspace_path, conversation_id, entry) do
          {:ok, content} -> [%Message{role: :user, content: content}]
          {:error, _reason} -> fallback_user(text, attachments)
        end

      role == "user" and is_binary(text) and text != "" ->
        [Message.user(text)]

      role == "assistant" and replayable_assistant?(entry) and is_binary(text) and text != "" ->
        [assistant_message(entry, text)]

      true ->
        []
    end
  end

  def to_messages(_, _, _), do: []

  # Failed or cancelled assistant text is a loop, not context. Replaying it
  # teaches the next turn to continue the same degenerate output.
  defp replayable_assistant?(entry) do
    entry["status"] not in ["error", "cancelled"]
  end

  defp replay_blocks(blocks) when is_list(blocks) do
    Enum.filter(blocks, fn
      %{"type" => "responses_reasoning", "item" => item} when is_map(item) ->
        reasoning_item?(item)

      %{type: "responses_reasoning", item: item} when is_map(item) ->
        reasoning_item?(item)

      _ ->
        false
    end)
  end

  defp replay_blocks(_), do: []

  defp reasoning_item?(%{"type" => "reasoning", "encrypted_content" => encrypted})
       when is_binary(encrypted) and encrypted != "",
       do: true

  defp reasoning_item?(%{type: "reasoning", encrypted_content: encrypted})
       when is_binary(encrypted) and encrypted != "",
       do: true

  defp reasoning_item?(_), do: false

  defp assistant_message(entry, text) do
    text_block =
      %{type: "text", text: text}
      |> maybe_put(:phase, entry["phase"])
      |> maybe_put(:id, entry["id"])

    case replay_blocks(entry["content_blocks"]) do
      [] ->
        if text_block[:phase] in ["commentary", "final_answer"],
          do: Message.assistant_blocks([text_block]),
          else: Message.assistant(text)

      blocks ->
        Message.assistant_blocks(blocks ++ [text_block])
    end
  end

  defp maybe_put(block, _key, value) when value in [nil, ""], do: block
  defp maybe_put(block, key, value), do: Map.put(block, key, value)

  defp rebuild_user(text, attachments, workspace_path, conversation_id, entry) do
    text_blocks =
      if is_binary(text) and String.trim(text) != "",
        do: [%{type: "text", text: text}],
        else: []

    blocks =
      Enum.reduce(attachments, text_blocks, fn att, acc ->
        acc ++ restore_attachment(att, workspace_path, conversation_id, entry)
      end)

    if blocks == [] do
      {:error, :empty}
    else
      {:ok, if(only_plain_text?(blocks), do: hd(blocks).text, else: blocks)}
    end
  end

  defp restore_attachment(att, workspace_path, conversation_id, entry) do
    mime = att["mime_type"] || att[:mime_type]
    name = att["filename"] || att[:filename] || "attachment"
    relative = att["relative_path"] || att[:relative_path]

    cond do
      not is_nil(att["storage_path"] || att[:storage_path]) ->
        [%{type: "text", text: "Image attachment rejected: absolute storage path (#{name})"}]

      Attachments.image?(to_string(mime)) ->
        case load_image(workspace_path, conversation_id, relative, mime, entry) do
          {:ok, data} ->
            [%{type: "image", mime_type: mime, data: data}]

          {:error, reason} ->
            [%{type: "text", text: "Image attachment missing (#{name}): #{inspect(reason)}"}]
        end

      Attachments.text?(to_string(mime)) ->
        [%{type: "text", text: "Attached text file #{name} at #{relative || name}."}]

      true ->
        [%{type: "text", text: "Attachment #{name} is not available in this history window."}]
    end
  end

  defp load_image(workspace_path, conversation_id, relative, mime, entry) do
    with {:ok, path} <- resolve_history_upload(workspace_path, conversation_id, relative, entry),
         :ok <- Access.verify_canonical(path, mime),
         {:ok, bin} <- Access.read_bounded(path, Attachments.max_image_bytes()) do
      {:ok, Base.encode64(bin)}
    end
  end

  defp resolve_history_upload(workspace_path, conversation_id, relative, _entry)
       when is_binary(workspace_path) and is_binary(conversation_id) and is_binary(relative) do
    Access.resolve_upload(workspace_path, conversation_id, relative)
  end

  defp resolve_history_upload(_workspace_path, conversation_id, relative, entry)
       when is_binary(conversation_id) and is_binary(relative) do
    if free_history?(entry) do
      Access.resolve_free_upload(conversation_id, Path.basename(relative))
    else
      {:error, :malformed_ref}
    end
  end

  defp resolve_history_upload(_, _, _, _), do: {:error, :malformed_ref}

  defp free_history?(entry) do
    entry["scope"] == "free" or get_in(entry, ["metadata", "scope"]) == "free"
  end

  defp only_plain_text?([%{type: "text", text: text}]) when is_binary(text), do: true
  defp only_plain_text?(_), do: false

  defp fallback_user(text, attachments) do
    names =
      attachments
      |> Enum.map(&(&1["filename"] || &1[:filename] || "attachment"))
      |> Enum.join(", ")

    notice = "Attachments could not be restored: #{names}"
    body = [text, notice] |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.join("\n")
    if body == "", do: [], else: [Message.user(body)]
  end
end

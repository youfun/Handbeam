defmodule Handbeam.Agent.ToolResultProjection do
  @moduledoc """
  Model-facing copy of messages for one provider call.

  The latest tool-use batch stays intact, including when a steer message
  follows those results. Earlier tool results longer than 2_000 bytes become
  one line that points at a file under `.handbeam/tool-results`. The file
  name includes a content hash, and an existing file is reused only when its
  bytes match. A `read_context` result stays, and so does every message before
  the accepted model-context prefix. `project/3` only rewrites the message
  list. `persist/2` writes the omitted bodies.
  """

  alias Handbeam.Agent.Message
  alias Handbeam.Security.PathValidator
  alias Handbeam.Utils.SafeMap

  @min_bytes 2_000
  @spill_pattern ~r/Full result written to (\.handbeam\/tool-results\/\S+) \((\d+) bytes\)/

  @type keep :: %{id: String.t(), relative: String.t(), content: String.t()}

  @spec retained([Message.t()], non_neg_integer()) :: [keep()]
  def retained(messages, suffix_from \\ 0) when is_list(messages) and is_integer(suffix_from) do
    {_prefix, suffix} = split_suffix(messages, suffix_from)
    current_ids = current_result_ids(suffix)
    view_ids = context_view_ids(messages)

    suffix
    |> Enum.flat_map(&keep_message(&1, current_ids, view_ids))
    |> Enum.uniq_by(& &1.id)
  end

  @spec persist([keep()], String.t() | nil) :: %{optional(String.t()) => :ok | :error}
  def persist(keeps, working_directory) when is_list(keeps) do
    Map.new(keeps, fn keep -> {keep.id, write_kept(keep, working_directory)} end)
  end

  @spec project([Message.t()], %{optional(String.t()) => :ok | :error}, non_neg_integer()) :: [
          Message.t()
        ]
  def project(messages, stored, suffix_from \\ 0)
      when is_list(messages) and is_map(stored) and is_integer(suffix_from) do
    {prefix, suffix} = split_suffix(messages, suffix_from)
    current_ids = current_result_ids(suffix)
    view_ids = context_view_ids(messages)
    prefix ++ Enum.map(suffix, &age_message(&1, stored, current_ids, view_ids))
  end

  defp split_suffix(messages, suffix_from) do
    Enum.split(messages, suffix_from |> max(0) |> min(length(messages)))
  end

  defp context_view_ids(messages) do
    messages
    |> Enum.flat_map(&view_tool_ids/1)
    |> MapSet.new()
  end

  defp view_tool_ids(%Message{role: :assistant, content: blocks}) when is_list(blocks) do
    Enum.flat_map(blocks, fn
      block when is_map(block) ->
        type = SafeMap.get_any(block, :type, "type")
        name = SafeMap.get_any(block, :name, "name")
        id = SafeMap.get_any(block, :id, "id")

        if type in ["tool_use", "server_tool_use"] and name == "read_context" and
             is_binary(id) and id != "" do
          [id]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp view_tool_ids(_message), do: []

  # The latest assistant tool-use batch is still unseen when no later
  # assistant message exists, even if a user steer sits after the results.
  defp current_result_ids(messages) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while(:searching, fn
      %Message{role: :assistant} = message, :searching ->
        case tool_use_ids(message) do
          [] -> {:halt, MapSet.new()}
          ids -> {:halt, MapSet.new(ids)}
        end

      _message, :searching ->
        {:cont, :searching}
    end)
    |> case do
      :searching -> trailing_result_ids(messages)
      ids -> ids
    end
  end

  defp trailing_result_ids(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&tool_result_message?/1)
    |> Enum.flat_map(&result_ids/1)
    |> MapSet.new()
  end

  defp tool_use_ids(%Message{role: :assistant, content: blocks}) when is_list(blocks) do
    Enum.flat_map(blocks, fn
      block when is_map(block) ->
        type = SafeMap.get_any(block, :type, "type")
        id = SafeMap.get_any(block, :id, "id")

        if type in ["tool_use", "server_tool_use"] and is_binary(id) and id != "" do
          [id]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp tool_use_ids(_message), do: []

  defp result_ids(%Message{content: blocks}) when is_list(blocks) do
    Enum.flat_map(blocks, fn
      block when is_map(block) ->
        id = SafeMap.get_any(block, :tool_use_id, "tool_use_id")
        if is_binary(id) and id != "", do: [id], else: []

      _ ->
        []
    end)
  end

  defp result_ids(_message), do: []

  defp tool_result_message?(%Message{role: :tool_result}), do: true
  defp tool_result_message?(_message), do: false

  defp keep_message(%Message{role: :tool_result, content: blocks}, current_ids, view_ids)
       when is_list(blocks) do
    Enum.flat_map(blocks, &keep_block(&1, current_ids, view_ids))
  end

  defp keep_message(_message, _current_ids, _view_ids), do: []

  defp keep_block(block, current_ids, view_ids) when is_map(block) do
    fields = block_fields(block)

    if omittable?(fields) and not spill_reference?(fields.content) and
         not current_result?(fields, current_ids) and not view_result?(fields, view_ids) do
      id = artifact_id(fields.tool_use_id, fields.content)

      [
        %{
          id: id,
          relative: kept_relative(id),
          content: fields.content
        }
      ]
    else
      []
    end
  end

  defp keep_block(_block, _current_ids, _view_ids), do: []

  defp age_message(
         %Message{role: :tool_result, content: blocks} = message,
         stored,
         current_ids,
         view_ids
       )
       when is_list(blocks) do
    aged = Enum.map(blocks, &age_block(&1, stored, current_ids, view_ids))
    if aged == blocks, do: message, else: %{message | content: aged}
  end

  defp age_message(message, _stored, _current_ids, _view_ids), do: message

  defp age_block(block, stored, current_ids, view_ids) when is_map(block) do
    fields = block_fields(block)

    cond do
      view_result?(fields, view_ids) ->
        block

      current_result?(fields, current_ids) ->
        block

      not omittable?(fields) ->
        block

      String.starts_with?(fields.content, "[Earlier tool result omitted") ->
        block

      true ->
        put_content(block, omission(fields, stored))
    end
  end

  defp age_block(block, _stored, _current_ids, _view_ids), do: block

  defp current_result?(fields, current_ids) do
    is_binary(fields.tool_use_id) and MapSet.member?(current_ids, fields.tool_use_id)
  end

  defp view_result?(fields, view_ids) do
    is_binary(fields.tool_use_id) and MapSet.member?(view_ids, fields.tool_use_id)
  end

  defp omittable?(fields) do
    fields.type in ["tool_result", "server_tool_result"] and
      not images?(fields.images) and
      is_binary(fields.content) and
      byte_size(fields.content) > @min_bytes
  end

  defp omission(fields, stored) do
    case reference(fields, stored) do
      {:ok, relative, bytes} ->
        "[Earlier tool result omitted from this request. Full output: #{relative} " <>
          "(#{bytes} bytes). Read it with the read tool using offset and limit. " <>
          "Do not assume the omitted body.]"

      :error ->
        String.slice(fields.content, 0, 500) <>
          "\n[Earlier tool result shortened. Full body was not retained for a later request.]"
    end
  end

  defp reference(fields, stored) do
    case Regex.run(@spill_pattern, fields.content) do
      [_, relative, bytes] ->
        {:ok, relative, bytes}

      _ ->
        id = artifact_id(fields.tool_use_id, fields.content)

        if Map.get(stored, id) == :ok do
          {:ok, kept_relative(id), Integer.to_string(byte_size(fields.content))}
        else
          :error
        end
    end
  end

  defp spill_reference?(content) do
    Regex.match?(@spill_pattern, content)
  end

  defp write_kept(_keep, working_directory)
       when not is_binary(working_directory) or working_directory == "",
       do: :error

  defp write_kept(keep, working_directory) do
    absolute = Path.expand(keep.relative, working_directory)

    with :ok <- File.mkdir_p(Path.dirname(absolute)),
         :ok <- PathValidator.validate_within_workspace(absolute, working_directory),
         :ok <- write_new(absolute, keep.content) do
      :ok
    else
      _ -> :error
    end
  end

  defp write_new(absolute, content) do
    cond do
      not File.exists?(absolute) ->
        File.write(absolute, content)

      File.read(absolute) == {:ok, content} ->
        :ok

      true ->
        :error
    end
  end

  defp kept_relative(id) do
    Path.join([".handbeam", "tool-results", "kept-#{id}.txt"])
  end

  defp artifact_id(id, content) do
    prefix =
      if is_binary(id) and id != "" do
        String.replace(id, ~r/[^A-Za-z0-9_-]/, "_")
      else
        "result"
      end

    prefix <> "-" <> content_hash(content)
  end

  defp content_hash(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp block_fields(block) do
    %{
      type: SafeMap.get_any(block, :type, "type"),
      content: SafeMap.get_any(block, :content, "content"),
      tool_use_id: SafeMap.get_any(block, :tool_use_id, "tool_use_id"),
      images: SafeMap.get_any(block, :images, "images")
    }
  end

  defp images?(images) when is_list(images) and images != [], do: true
  defp images?(_images), do: false

  defp put_content(block, content) do
    cond do
      Map.has_key?(block, :content) -> %{block | content: content}
      Map.has_key?(block, "content") -> Map.put(block, "content", content)
      true -> Map.put(block, :content, content)
    end
  end
end

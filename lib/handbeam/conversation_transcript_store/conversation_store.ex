defmodule Handbeam.ConversationTranscriptStore.ConversationStore do
  @moduledoc """
  File-backed transcript store using `Handbeam.ConversationStore` messages.jsonl.
  """

  @behaviour Handbeam.ConversationTranscriptStore

  require Logger

  @impl true
  def list(conversation_id, _opts) do
    {:ok, Handbeam.ConversationStore.load_messages(conversation_id)}
  end

  @impl true
  def append(conversation_id, entry, opts) do
    with_lock(conversation_id, fn ->
      normalized = normalize_entry(conversation_id, entry, opts)

      case Handbeam.ConversationStore.append_message(conversation_id, normalized) do
        :ok ->
          touch_meta(conversation_id)
          {:ok, normalized}

        {:error, reason} ->
          Logger.debug(
            "[TranscriptStore] append failed conversation=#{conversation_id} reason=#{inspect(reason)}"
          )

          {:error, reason}
      end
    end)
  end

  @impl true
  def update(conversation_id, entry_id, patch, _opts) do
    with_lock(conversation_id, fn ->
      entries = Handbeam.ConversationStore.load_messages(conversation_id)

      case Enum.split_with(entries, &(Map.get(&1, "id") != entry_id)) do
        {_before, []} ->
          {:error, :not_found}

        _ ->
          {updated_entries, updated_entry} =
            Enum.map_reduce(entries, nil, fn entry, found ->
              if Map.get(entry, "id") == entry_id do
                updated =
                  entry
                  |> deep_merge(stringify_keys(patch))
                  |> Map.put("updated_at", now_iso8601())

                {updated, updated}
              else
                {entry, found}
              end
            end)

          with :ok <-
                 Handbeam.ConversationStore.replace_messages(conversation_id, updated_entries) do
            touch_meta(conversation_id)
            {:ok, updated_entry}
          end
      end
    end)
  end

  @impl true
  def delete(conversation_id, entry_id, _opts) do
    with_lock(conversation_id, fn ->
      entries = Handbeam.ConversationStore.load_messages(conversation_id)
      remaining = Enum.reject(entries, &(Map.get(&1, "id") == entry_id))

      if remaining == entries do
        :ok
      else
        with :ok <- Handbeam.ConversationStore.replace_messages(conversation_id, remaining) do
          touch_meta(conversation_id)
          :ok
        end
      end
    end)
  end

  @impl true
  def replace_all(conversation_id, entries, _opts) do
    with_lock(conversation_id, fn ->
      entries =
        entries
        |> Enum.with_index(1)
        |> Enum.map(fn {entry, index} ->
          normalize_entry(conversation_id, entry, sequence: index)
        end)

      case Handbeam.ConversationStore.replace_messages(conversation_id, entries) do
        :ok ->
          touch_meta(conversation_id)
          :ok

        other ->
          other
      end
    end)
  end

  defp with_lock(conversation_id, fun) do
    :global.trans({{__MODULE__, conversation_id}, self()}, fun)
  end

  defp normalize_entry(conversation_id, entry, opts) do
    now = now_iso8601()

    entry
    |> stringify_keys()
    |> Map.put_new("id", unique_id("msg"))
    |> Map.put_new("conversation_id", conversation_id)
    |> Map.put_new("sequence", Keyword.get(opts, :sequence, next_sequence(conversation_id)))
    |> Map.put_new("created_at", now)
    |> Map.put("updated_at", Map.get(entry, "updated_at") || Map.get(entry, :updated_at) || now)
  end

  defp next_sequence(conversation_id) do
    conversation_id
    |> Handbeam.ConversationStore.load_messages()
    |> length()
    |> Kernel.+(1)
  end

  defp touch_meta(conversation_id) do
    case Handbeam.ConversationStore.update_meta(conversation_id, []) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp stringify_keys(%{__struct__: _} = struct) do
    struct |> Map.from_struct() |> stringify_keys()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      cond do
        is_binary(left_value) and is_map(right_value) and is_binary(right_value["$append"]) ->
          left_value <> right_value["$append"]

        is_nil(left_value) and is_map(right_value) and is_binary(right_value["$append"]) ->
          right_value["$append"]

        is_map(left_value) and is_map(right_value) ->
          deep_merge(left_value, right_value)

        true ->
          right_value
      end
    end)
  end

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end

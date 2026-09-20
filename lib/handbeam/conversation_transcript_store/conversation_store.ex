defmodule Handbeam.ConversationTranscriptStore.ConversationStore do
  @moduledoc """
  File-backed transcript store using `Handbeam.ConversationStore` messages.jsonl.
  """

  @behaviour Handbeam.ConversationTranscriptStore

  alias Handbeam.ConversationTranscriptStore.Journal

  require Logger

  @impl true
  def list(conversation_id, opts) do
    if Handbeam.ConversationStore.internal?(conversation_id) and
         not runtime_reader?(conversation_id, opts) do
      with {:ok, conversation} <- Handbeam.ConversationStore.get(conversation_id, opts) do
        {:ok, conversation["timeline"]}
      end
    else
      Handbeam.ConversationStore.load_messages_result(conversation_id)
    end
  end

  # Cancellation must read its own running tool entries after closing admission.
  # Require the actual registered Runner caller, not just model-supplied ids.
  defp runtime_reader?(id, opts) do
    caller = self()
    run_id = opts[:run_id]

    opts[:runner_pid] == caller and is_binary(run_id) and
      match?([{^caller, %{run_id: ^run_id}}], Registry.lookup(Handbeam.AgentRunRegistry, id))
  end

  @impl true
  def append(conversation_id, entry, opts) do
    with {:ok, _meta} <- Handbeam.ConversationStore.get_meta(conversation_id) do
      normalized = normalize_entry(conversation_id, entry, opts)

      case Journal.append(Handbeam.ConversationStore.messages_path(conversation_id), normalized) do
        {:ok, persisted} ->
          touch_meta(conversation_id)
          {:ok, persisted}

        {:error, reason} ->
          Logger.debug(
            "[TranscriptStore] append failed conversation=#{conversation_id} reason=#{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  @impl true
  def update(conversation_id, entry_id, patch, _opts) do
    Journal.update(
      Handbeam.ConversationStore.messages_path(conversation_id),
      entry_id,
      stringify_keys(patch),
      now_iso8601()
    )
  end

  @impl true
  def delete(conversation_id, entry_id, _opts) do
    Journal.delete(Handbeam.ConversationStore.messages_path(conversation_id), entry_id)
  end

  @impl true
  def replace_all(conversation_id, entries, _opts) do
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
  end

  defp normalize_entry(conversation_id, entry, opts) do
    now = now_iso8601()

    entry
    |> stringify_keys()
    |> Map.put_new("id", unique_id("msg"))
    |> Map.put_new("conversation_id", conversation_id)
    |> maybe_put_sequence(opts)
    |> Map.put_new("created_at", now)
    |> Map.put("updated_at", Map.get(entry, "updated_at") || Map.get(entry, :updated_at) || now)
  end

  defp maybe_put_sequence(entry, opts) do
    case Keyword.fetch(opts, :sequence) do
      {:ok, sequence} -> Map.put_new(entry, "sequence", sequence)
      :error -> entry
    end
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

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp unique_id(prefix) do
    "#{prefix}-#{Ecto.UUID.generate()}"
  end
end

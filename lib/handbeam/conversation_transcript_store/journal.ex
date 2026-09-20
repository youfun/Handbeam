defmodule Handbeam.ConversationTranscriptStore.Journal do
  @moduledoc """
  Serialized, append-only owner for transcript JSONL files.

  Existing plain JSON objects are snapshot entries. Revisions use
  `{"$handbeam_journal":1,"op":"update"|"delete",...}` records. A reader
  replays both forms in order. The last unterminated malformed line is ignored
  as a crash remnant; malformed records anywhere else fail the read.

  `replace/2` is the compaction operation: it atomically writes the current
  entries as plain JSONL. Callers may invoke it manually; replacing a
  conversation timeline also compacts it. The in-memory cache is LRU bounded.
  """

  use GenServer

  require Logger

  @name __MODULE__
  @max_cached_paths 64
  @version 1

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  def load(path), do: call({:load, Path.expand(path)})
  def append(path, entry), do: call({:append, Path.expand(path), entry})

  def update(path, id, patch, updated_at),
    do: call({:update, Path.expand(path), id, patch, updated_at})

  def delete(path, id), do: call({:delete, Path.expand(path), id})
  def replace(path, entries), do: call({:replace, Path.expand(path), entries})
  def invalidate(path), do: call({:invalidate, Path.expand(path)})

  @impl true
  def init(_opts), do: {:ok, %{cache: %{}, clock: 0}}

  @impl true
  def handle_call({:invalidate, path}, _from, state),
    do: {:reply, :ok, %{state | cache: Map.delete(state.cache, path)}}

  def handle_call({:load, path}, _from, state) do
    case fetch(state, path) do
      {:ok, journal, state} -> {:reply, {:ok, materialize(journal)}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:append, path, entry}, _from, state) do
    with {:ok, journal, state} <- fetch(state, path) do
      entry = Map.put_new(entry, "sequence", journal.next_sequence)

      case append_record(path, entry, journal.valid_offset) do
        :ok ->
          journal = put_entry(journal, entry) |> refresh_offset(path)
          {:reply, {:ok, entry}, cache(state, path, journal)}

        {:error, reason} ->
          {:reply, {:error, reason}, invalidate_state(state, path)}
      end
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update, path, id, patch, updated_at}, _from, state) do
    with {:ok, journal, state} <- fetch(state, path),
         {:ok, old} <- Map.fetch(journal.by_id, id) do
      patch = Map.put(patch, "updated_at", updated_at)
      updated = deep_merge(old, patch)
      record = %{"$handbeam_journal" => @version, "op" => "update", "id" => id, "patch" => patch}

      case append_record(path, record, journal.valid_offset) do
        :ok ->
          journal = replace_entry(journal, id, updated) |> refresh_offset(path)
          {:reply, {:ok, updated}, cache(state, path, journal)}

        {:error, reason} ->
          {:reply, {:error, reason}, invalidate_state(state, path)}
      end
    else
      :error -> {:reply, {:error, :not_found}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete, path, id}, _from, state) do
    with {:ok, journal, state} <- fetch(state, path) do
      if Map.has_key?(journal.by_id, id) do
        record = %{"$handbeam_journal" => @version, "op" => "delete", "id" => id}

        case append_record(path, record, journal.valid_offset) do
          :ok ->
            journal = remove_entry(journal, id) |> refresh_offset(path)
            {:reply, :ok, cache(state, path, journal)}

          {:error, reason} ->
            {:reply, {:error, reason}, invalidate_state(state, path)}
        end
      else
        {:reply, :ok, state}
      end
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replace, path, entries}, _from, state) do
    entries = Enum.map(entries, &Handbeam.JsonSafe.normalize/1)

    case encode_lines(entries) do
      {:ok, data} ->
        case atomic_write(path, data) do
          :ok -> {:reply, :ok, cache(state, path, build(entries) |> refresh_offset(path))}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp call(message) do
    GenServer.call(@name, message, :infinity)
  end

  defp fetch(state, path) do
    case state.cache[path] do
      nil ->
        case replay(path) do
          {:ok, journal} -> {:ok, journal, cache(state, path, journal)}
          {:error, reason} -> {:error, reason, state}
        end

      %{journal: journal, signature: cached_signature} ->
        if cached_signature == signature(path) do
          {:ok, journal, touch(state, path)}
        else
          case replay(path) do
            {:ok, journal} -> {:ok, journal, cache(state, path, journal)}
            {:error, reason} -> {:error, reason, state}
          end
        end
    end
  end

  defp replay(path) do
    case File.read(path) do
      {:ok, content} -> replay_content(content)
      {:error, :enoent} -> {:ok, build([])}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replay_content(content) do
    terminated? = content == "" or String.ends_with?(content, "\n")
    lines = String.split(content, "\n", trim: false)
    lines = if terminated?, do: Enum.drop(lines, -1), else: lines

    lines
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, build([]), 0, false}, fn {line, index},
                                                        {:ok, journal, offset, false} ->
      case Handbeam.JSON.decode(line) do
        {:ok, record} when is_map(record) ->
          case replay_record(journal, record) do
            {:ok, journal} ->
              {:cont,
               {:ok, journal, min(byte_size(content), offset + byte_size(line) + 1), false}}

            {:error, reason} ->
              {:halt, {:error, {:corrupt_journal, index + 1, reason}}}
          end

        _ when not terminated? and index == length(lines) - 1 ->
          {:cont, {:ok, journal, offset, true}}

        _ ->
          {:halt, {:error, {:corrupt_journal, index + 1}}}
      end
    end)
    |> case do
      {:ok, journal, offset, ignored_tail?} ->
        # A valid unterminated final JSON object is durable; appends first add its newline.
        valid_offset = if ignored_tail?, do: offset, else: byte_size(content)
        {:ok, %{journal | valid_offset: valid_offset}}

      error ->
        error
    end
  end

  defp replay_record(journal, %{
         "$handbeam_journal" => @version,
         "op" => "update",
         "id" => id,
         "patch" => patch
       })
       when is_map(patch) do
    case journal.by_id[id] do
      nil -> {:ok, journal}
      entry -> {:ok, replace_entry(journal, id, deep_merge(entry, patch))}
    end
  end

  defp replay_record(journal, %{"$handbeam_journal" => @version, "op" => "delete", "id" => id}),
    do: {:ok, remove_entry(journal, id)}

  defp replay_record(_journal, %{"$handbeam_journal" => version}),
    do: {:error, {:unsupported_version, version}}

  defp replay_record(journal, entry), do: {:ok, put_entry(journal, entry)}

  defp build(entries),
    do:
      Enum.reduce(
        entries,
        %{
          by_slot: %{},
          by_id: %{},
          id_to_slot: %{},
          next_slot: 0,
          next_sequence: 1,
          valid_offset: 0
        },
        &put_entry(&2, &1)
      )

  defp put_entry(journal, entry) do
    id = entry["id"]

    slot = if is_binary(id), do: journal.id_to_slot[id], else: nil
    slot = slot || journal.next_slot
    by_slot = Map.put(journal.by_slot, slot, entry)

    id_to_slot =
      if is_binary(id), do: Map.put(journal.id_to_slot, id, slot), else: journal.id_to_slot

    next_slot = if slot == journal.next_slot, do: slot + 1, else: journal.next_slot

    by_id = if is_binary(id), do: Map.put(journal.by_id, id, entry), else: journal.by_id
    sequence = entry["sequence"]

    next_sequence =
      if is_integer(sequence),
        do: max(journal.next_sequence, sequence + 1),
        else: journal.next_sequence + 1

    %{
      journal
      | by_slot: by_slot,
        by_id: by_id,
        id_to_slot: id_to_slot,
        next_slot: next_slot,
        next_sequence: next_sequence
    }
  end

  defp replace_entry(journal, id, entry),
    do: %{
      journal
      | by_slot: Map.put(journal.by_slot, journal.id_to_slot[id], entry),
        by_id: Map.put(journal.by_id, id, entry)
    }

  defp remove_entry(journal, id),
    do: %{
      journal
      | by_slot: Map.delete(journal.by_slot, journal.id_to_slot[id]),
        by_id: Map.delete(journal.by_id, id),
        id_to_slot: Map.delete(journal.id_to_slot, id)
    }

  defp materialize(journal),
    do: journal.by_slot |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

  defp append_record(path, record, valid_offset) do
    with {:ok, json} <- Handbeam.JSON.encode(Handbeam.JsonSafe.normalize(record)),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- File.open(path, [:read, :write, :binary]) do
      {:ok, eof} = :file.position(io, :eof)
      # Remove an ignored malformed tail. Preserve valid unterminated JSON by delimiting it.
      prefix =
        if eof == valid_offset and valid_offset > 0 and not ends_in_newline?(io, eof),
          do: "\n",
          else: ""

      rollback_offset = valid_offset

      result =
        with {:ok, _} <- :file.position(io, valid_offset),
             :ok <- :file.truncate(io),
             :ok <- IO.binwrite(io, prefix <> json <> "\n"),
             :ok <- :file.sync(io),
             do: :ok

      if result != :ok do
        rollback_result = rollback(io, rollback_offset)

        Logger.error(
          "[TranscriptJournal] append persistence failed path=#{path} reason=#{inspect(result)} rollback=#{inspect(rollback_result)}"
        )
      end

      File.close(io)
      result
    end
  end

  defp rollback(io, offset) do
    with {:ok, _} <- :file.position(io, offset), :ok <- :file.truncate(io), do: :file.sync(io)
  end

  defp ends_in_newline?(io, eof) do
    with {:ok, _} <- :file.position(io, eof - 1),
         {:ok, "\n"} <- :file.read(io, 1),
         do: true,
         else: (_ -> false)
  end

  defp refresh_offset(journal, path) do
    case File.stat(path) do
      {:ok, stat} -> %{journal | valid_offset: stat.size}
      _ -> journal
    end
  end

  defp invalidate_state(state, path), do: %{state | cache: Map.delete(state.cache, path)}

  defp encode_lines(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, lines} ->
      case Handbeam.JSON.encode(Handbeam.JsonSafe.normalize(entry)) do
        {:ok, json} -> {:cont, {:ok, [json <> "\n" | lines]}}
        {:error, _} -> {:halt, {:error, :encode_failed}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, reversed |> Enum.reverse() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp atomic_write(path, data) do
    tmp = path <> ".tmp.#{System.unique_integer([:positive])}"

    result =
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(tmp, data, [:binary, :sync]),
           :ok <- File.rename(tmp, path),
           do: :ok

    File.rm(tmp)
    result
  end

  defp cache(state, path, journal) do
    clock = state.clock + 1

    cache =
      Map.put(state.cache, path, %{journal: journal, used: clock, signature: signature(path)})

    cache =
      if map_size(cache) > @max_cached_paths,
        do: Map.delete(cache, cache |> Enum.min_by(fn {_p, value} -> value.used end) |> elem(0)),
        else: cache

    %{state | cache: cache, clock: clock}
  end

  defp touch(state, path), do: cache(state, path, state.cache[path].journal)

  defp signature(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {stat.size, stat.mtime, stat.ctime, stat.inode}
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, l, r ->
      cond do
        (is_binary(l) or is_nil(l)) and is_map(r) and is_binary(r["$append"]) ->
          (l || "") <> r["$append"]

        is_map(l) and is_map(r) ->
          deep_merge(l, r)

        true ->
          r
      end
    end)
  end
end

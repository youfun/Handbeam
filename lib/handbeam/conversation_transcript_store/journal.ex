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
  @compact_after 256
  @retry_ms 1_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  def load(path), do: call({:load, Path.expand(path)})
  def page(path, opts), do: call({:page, Path.expand(path), opts})
  def append(path, entry), do: call({:append, Path.expand(path), entry})

  def update(path, id, patch, updated_at),
    do: call({:update, Path.expand(path), id, patch, updated_at})

  def delete(path, id), do: call({:delete, Path.expand(path), id})
  def replace(path, entries), do: call({:replace, Path.expand(path), entries})
  def invalidate(path), do: call({:invalidate, Path.expand(path)})

  def read_file(root, path),
    do: call({:read_file, Path.expand(root), Path.expand(path)})

  def write_file(root, path, data) when is_binary(data),
    do: call({:write_file, Path.expand(root), Path.expand(path), data})

  def write_json(root, path, data) do
    with {:ok, encoded} <- Handbeam.JSON.encode(Handbeam.JsonSafe.normalize(data)) do
      write_file(root, path, encoded)
    end
  end

  @impl true
  def init(_opts),
    do: {:ok, %{cache: %{}, clock: 0, pending: MapSet.new(), retry_timer: nil, locks: %{}}}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.locks, fn {_key, %{resource: resource}} ->
      :handbeam_storage.close(resource)
    end)

    :ok
  end

  @impl true
  def handle_call({:invalidate, path}, _from, state),
    do: {:reply, :ok, %{state | cache: Map.delete(state.cache, path)}}

  def handle_call({:read_file, root, path}, _from, state) do
    with :ok <- validate_path(root, path),
         {:ok, _resource, state} <- ensure_lock(state, root) do
      {:reply, File.read(path), state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:write_file, root, path, data}, _from, state) do
    with :ok <- validate_path(root, path),
         {:ok, resource, state} <- ensure_lock(state, root) do
      result = native_replace(resource, path, data)
      {:reply, result, %{state | cache: Map.delete(state.cache, path)}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:load, path}, _from, state) do
    case fetch_locked(state, path) do
      {:ok, journal, state} -> {:reply, {:ok, materialize(journal)}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:page, path, opts}, _from, state) do
    with {:ok, journal, state} <- fetch_locked(state, path) do
      {:reply, page_entries(journal, opts), state}
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:append, path, entry}, _from, state) do
    with {:ok, journal, state} <- fetch_locked(state, path) do
      entry = Map.put_new(entry, "sequence", journal.next_sequence)
      mutate(path, %{"op" => "append", "entry" => entry}, journal, state, {:ok, entry})
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update, path, id, patch, updated_at}, _from, state) do
    with {:ok, journal, state} <- fetch_locked(state, path) do
      case Map.fetch(journal.by_id, id) do
        {:ok, old} ->
          patch = Map.put(patch, "updated_at", updated_at)
          updated = deep_merge(old, patch)
          record = %{"op" => "update", "id" => id, "patch" => patch}
          mutate(path, record, journal, state, {:ok, updated})

        :error ->
          {:reply, {:error, :not_found}, state}
      end
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete, path, id}, _from, state) do
    with {:ok, journal, state} <- fetch_locked(state, path) do
      if Map.has_key?(journal.by_id, id) do
        mutate(path, %{"op" => "delete", "id" => id}, journal, state, :ok)
      else
        {:reply, :ok, state}
      end
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replace, path, entries}, _from, state) do
    with {:ok, journal, state} <- fetch_locked(state, path) do
      entries = Enum.map(entries, &Handbeam.JsonSafe.normalize/1)
      mutate(path, %{"op" => "replace", "entries" => entries}, journal, state, :ok)
    else
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:retry_pending, state) do
    state = %{state | retry_timer: nil}

    state =
      Enum.reduce(state.pending, state, fn path, state ->
        case fetch_locked(state, path) do
          {:ok, _journal, state} ->
            if pid = Process.whereis(Handbeam.Agent.TranscriptRecovery),
              do: send(pid, {:transcript_retry_persisted, Path.basename(Path.dirname(path))})

            state

          {:error, _reason, state} ->
            state
        end
      end)

    {:noreply, state}
  end

  defp mutate(path, record, journal, state, reply) do
    record =
      Map.merge(record, %{"$handbeam_journal" => @version, "txid" => journal.last_txid + 1})

    with {:ok, _validated} <- replay_record(journal, record),
         {:ok, encoded} <- encode_lines([record]),
         {:ok, resource, state} <- lock_for_path(state, path) do
      case native_replace(resource, pending_path(path), encoded) do
        :ok ->
          case drain_pending(path, journal, resource) do
            {:ok, journal} ->
              journal = maybe_compact(path, journal, resource)
              {:reply, reply, cache(clear_pending(state, path), path, journal)}

            {:error, reason} ->
              {:reply, {:error, {:queued, reason}},
               retry_later(invalidate_state(state, path), path)}
          end

        {:error, reason} ->
          # rename may have succeeded before directory fsync failed. The
          # visible intent owns this delta even though durability is uncertain;
          # keeping a second process-local copy would double-append on retry.
          if File.read(pending_path(path)) == {:ok, encoded} do
            {:reply, {:error, {:queued, reason}},
             retry_later(invalidate_state(state, path), path)}
          else
            {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp pending_path(path), do: path <> ".pending"

  defp drain_pending(path, journal, resource) do
    case File.read(pending_path(path)) do
      {:error, :enoent} ->
        {:ok, journal}

      {:error, reason} ->
        {:error, reason}

      {:ok, encoded} ->
        with {:ok, %{"txid" => txid} = record} when is_integer(txid) and txid > 0 <-
               Handbeam.JSON.decode(encoded),
             {:ok, updated} <- replay_record(journal, record),
             :ok <- persist_pending(path, record, journal, resource),
             :ok <- :handbeam_storage.remove_sync(resource, pending_path(path)) do
          {:ok, refresh_offset(updated, path)}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :corrupt_pending_record}
        end
    end
  end

  defp persist_pending(_path, %{"txid" => txid}, %{last_txid: persisted}, _resource)
       when txid <= persisted,
       do: :ok

  defp persist_pending(path, record, journal, resource),
    do: append_record(resource, path, record, journal.valid_offset)

  defp retry_later(state, path) do
    if File.exists?(pending_path(path)) do
      timer = state.retry_timer || Process.send_after(self(), :retry_pending, @retry_ms)
      %{state | pending: MapSet.put(state.pending, path), retry_timer: timer}
    else
      state
    end
  end

  defp clear_pending(state, path), do: %{state | pending: MapSet.delete(state.pending, path)}

  defp maybe_compact(path, journal, resource) do
    if journal.revisions >= max(@compact_after, map_size(journal.by_id)) do
      checkpoint = %{
        "$handbeam_journal" => @version,
        "op" => "checkpoint",
        "next_sequence" => journal.next_sequence,
        "last_txid" => journal.last_txid
      }

      with {:ok, data} <- encode_lines(materialize(journal) ++ [checkpoint]),
           :ok <- native_replace(resource, path, data) do
        %{journal | revisions: 0} |> refresh_offset(path)
      else
        {:error, reason} ->
          Logger.warning("[TranscriptJournal] compaction deferred: #{inspect(reason)}")
          # An atomic rename can precede a failed directory fsync. Both files
          # describe the same entries, but their append offsets differ.
          refresh_offset(journal, path)
      end
    else
      journal
    end
  end

  defp call(message) do
    GenServer.call(@name, message, :infinity)
  end

  defp fetch_locked(state, path) do
    with {:ok, resource, state} <- lock_for_path(state, path) do
      fetch(state, path, resource)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp fetch(state, path, resource) do
    with {:ok, journal, state} <- fetch_cached(state, path),
         {:ok, journal} <- drain_pending(path, journal, resource) do
      {:ok, journal, cache(clear_pending(state, path), path, journal)}
    else
      {:error, reason, state} -> {:error, reason, retry_later(state, path)}
      {:error, reason} -> {:error, reason, retry_later(invalidate_state(state, path), path)}
    end
  end

  defp fetch_cached(state, path) do
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

  defp replay_record(%{last_txid: persisted} = journal, %{
         "$handbeam_journal" => @version,
         "txid" => txid
       })
       when is_integer(txid) and txid > 0 and txid <= persisted,
       do: {:ok, journal}

  defp replay_record(journal, record) do
    txid = if Map.has_key?(record, "$handbeam_journal"), do: Map.get(record, "txid")

    with :ok <- validate_txid(record, txid),
         {:ok, updated} <- apply_record(journal, record) do
      {:ok, %{updated | last_txid: txid || updated.last_txid}}
    end
  end

  defp validate_txid(%{"$handbeam_journal" => @version}, txid)
       when is_integer(txid) and txid > 0, do: :ok

  defp validate_txid(%{"$handbeam_journal" => @version, "op" => "checkpoint"}, nil), do: :ok
  # Version 1 revisions shipped before the retry journal had transaction IDs.
  defp validate_txid(%{"$handbeam_journal" => @version} = record, nil) do
    if Map.has_key?(record, "txid"), do: {:error, :invalid_txid}, else: :ok
  end

  defp validate_txid(%{"$handbeam_journal" => @version}, _), do: {:error, :invalid_txid}
  defp validate_txid(_ordinary_entry, _), do: :ok

  defp apply_record(journal, %{
         "$handbeam_journal" => @version,
         "op" => "append",
         "entry" => entry
       })
       when is_map(entry), do: {:ok, put_entry(journal, entry)}

  defp apply_record(journal, %{
         "$handbeam_journal" => @version,
         "op" => "replace",
         "entries" => entries
       })
       when is_list(entries) do
    if Enum.all?(entries, &is_map/1) do
      replaced = build(entries)

      {:ok,
       %{
         replaced
         | revisions: max(@compact_after, map_size(replaced.by_id)),
           next_sequence: max(replaced.next_sequence, journal.next_sequence)
       }}
    else
      {:error, :invalid_replace_entries}
    end
  end

  defp apply_record(journal, %{
         "$handbeam_journal" => @version,
         "op" => "checkpoint",
         "next_sequence" => next_sequence,
         "last_txid" => txid
       })
       when is_integer(next_sequence) and next_sequence > 0 and is_integer(txid) and txid > 0,
       do: {:ok, %{journal | next_sequence: next_sequence, last_txid: txid, revisions: 0}}

  defp apply_record(journal, %{
         "$handbeam_journal" => @version,
         "op" => "update",
         "id" => id,
         "patch" => patch
       })
       when is_map(patch) do
    case journal.by_id[id] do
      nil -> {:ok, journal}
      entry -> {:ok, replace_entry(journal, id, deep_merge(entry, patch)) |> revision()}
    end
  end

  defp apply_record(journal, %{"$handbeam_journal" => @version, "op" => "delete", "id" => id}),
    do: {:ok, remove_entry(journal, id) |> revision()}

  defp apply_record(_journal, %{"$handbeam_journal" => version}),
    do: {:error, {:unsupported_version, version}}

  defp apply_record(journal, entry), do: {:ok, put_entry(journal, entry)}

  defp revision(journal), do: %{journal | revisions: journal.revisions + 1}

  defp build(entries),
    do:
      Enum.reduce(
        entries,
        %{
          by_slot: :gb_trees.empty(),
          by_id: %{},
          id_to_slot: %{},
          next_slot: 0,
          next_sequence: 1,
          valid_offset: 0,
          revisions: 0,
          last_txid: 0
        },
        &put_entry(&2, &1)
      )

  defp put_entry(journal, entry) do
    id = entry["id"]

    slot = if is_binary(id), do: journal.id_to_slot[id], else: nil
    slot = slot || journal.next_slot
    by_slot = :gb_trees.enter(slot, entry, journal.by_slot)

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
      | by_slot: :gb_trees.enter(journal.id_to_slot[id], entry, journal.by_slot),
        by_id: Map.put(journal.by_id, id, entry)
    }

  defp remove_entry(journal, id),
    do: %{
      journal
      | by_slot: :gb_trees.delete_any(journal.id_to_slot[id], journal.by_slot),
        by_id: Map.delete(journal.by_id, id),
        id_to_slot: Map.delete(journal.id_to_slot, id)
    }

  defp materialize(journal),
    do: :gb_trees.values(journal.by_slot)

  defp page_entries(journal, opts) do
    limit = Keyword.get(opts, :limit, 100)
    before_id = Keyword.get(opts, :before)
    slot = if before_id, do: journal.id_to_slot[before_id], else: journal.next_slot

    cond do
      not is_integer(limit) or limit < 1 or limit > 200 ->
        {:error, :invalid_limit}

      is_nil(slot) ->
        {:error, :invalid_cursor}

      true ->
        iterator = :gb_trees.iterator_from(slot - 1, journal.by_slot, :reversed)
        {entries, more?} = take_page(iterator, limit, [])
        cursor = if more?, do: hd(entries)["id"]
        {:ok, %{entries: entries, before: cursor, has_more?: more?}}
    end
  end

  defp take_page(iterator, 0, entries), do: {entries, :gb_trees.next(iterator) != :none}

  defp take_page(iterator, remaining, entries) do
    case :gb_trees.next(iterator) do
      :none -> {entries, false}
      {_slot, entry, next} -> take_page(next, remaining - 1, [entry | entries])
    end
  end

  defp append_record(resource, path, record, valid_offset) do
    with {:ok, json} <- Handbeam.JSON.encode(Handbeam.JsonSafe.normalize(record)),
         :ok <- mkdir_parent(path) do
      eof =
        case File.stat(path) do
          {:ok, stat} -> stat.size
          {:error, :enoent} -> 0
        end

      # Remove an ignored malformed tail. Preserve valid unterminated JSON by delimiting it.
      prefix =
        if eof == valid_offset and valid_offset > 0 and not ends_in_newline?(path, eof),
          do: "\n",
          else: ""

      :handbeam_storage.append_sync(resource, path, valid_offset, prefix <> json <> "\n")
    end
  end

  defp ends_in_newline?(path, eof) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          :file.pread(io, eof - 1, 1) == {:ok, "\n"}
        after
          :file.close(io)
        end

      {:error, _} ->
        false
    end
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

  defp native_replace(resource, path, data) do
    with :ok <- mkdir_parent(path), do: :handbeam_storage.replace_sync(resource, path, data)
  end

  defp lock_for_path(state, path), do: ensure_lock(state, root_for(path))

  defp root_for(path) do
    items = path |> Path.dirname() |> Path.dirname()

    if Path.basename(items) == "items",
      do: Path.dirname(items),
      else: Path.dirname(path)
  end

  defp ensure_lock(state, root) do
    with :ok <- File.mkdir_p(root),
         {:ok, stat} <- File.stat(root) do
      key = {stat.major_device, stat.minor_device, stat.inode}

      case state.locks[key] do
        %{resource: resource} ->
          {:ok, resource, state}

        nil ->
          lock_path = Path.join(root, ".handbeam-storage.lock")

          case :handbeam_storage.lock(lock_path) do
            {:ok, resource} ->
              lock = %{resource: resource, root: root, lock_path: lock_path}
              {:ok, resource, %{state | locks: Map.put(state.locks, key, lock)}}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  defp validate_path(root, path) do
    if inside_root?(root, path), do: :ok, else: {:error, :outside_storage_root}
  end

  defp inside_root?(root, path) do
    relative = Path.relative_to(path, root)
    relative != ".." and not String.starts_with?(relative, "../") and relative != path
  end

  defp mkdir_parent(path), do: File.mkdir_p(Path.dirname(path))

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

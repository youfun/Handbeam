defmodule Handbeam.Agent.OperationReceipt do
  @moduledoc """
  Durable reservation and receipt for one user operation.

  Storage follows the transcript journal: append-only JSONL under the
  conversation storage root, rewritten atomically on each mutation. A crash
  remnant is the last unterminated line and is ignored. Pending reservations
  recovered after restart stay `:unknown` and are not replayed.

  `request_id` is an operation id, not a conversation or run id. Callers that
  omit it keep the previous path and are not safe to retry. The same id and
  fingerprint returns the stored receipt. The same id with different content
  is `:idempotency_conflict`. Concurrent reserves of a new id accept one
  writer; the other sees the reservation.

  This is not exactly-once. A local timeout does not prove the remote side
  did not act.
  """

  @version 1

  def reserve(scope, request_id, fingerprint, opts \\ [])

  def reserve(_scope, request_id, _fingerprint, _opts) when request_id in [nil, ""], do: :ok

  def reserve(scope, request_id, fingerprint, opts) when is_binary(request_id) do
    path = path(scope, opts)

    with_lock(path, fn ->
      case read_records(path) do
        {:error, :corrupt} ->
          {:error, :delivery_unknown}

        {:ok, records} ->
          case Map.get(records, request_id) do
            %{"fingerprint" => ^fingerprint, "status" => "completed", "receipt" => receipt} ->
              {:replay, receipt}

            %{"fingerprint" => ^fingerprint, "status" => "reserved"} ->
              updated = %{Map.get(records, request_id) | "status" => "unknown"}
              write_records(path, Map.put(records, request_id, updated))
              {:unknown, :delivery_unknown}

            %{"fingerprint" => ^fingerprint, "status" => "unknown"} ->
              {:unknown, :delivery_unknown}

            %{"fingerprint" => other} when other != fingerprint ->
              {:error, :idempotency_conflict}

            nil ->
              record = %{
                "request_id" => request_id,
                "fingerprint" => fingerprint,
                "status" => "reserved",
                "receipt" => nil
              }

              write_records(path, Map.put(records, request_id, record))
              :ok
          end
      end
    end)
  end

  def complete(scope, request_id, receipt, opts \\ [])

  def complete(_scope, request_id, _receipt, _opts) when request_id in [nil, ""], do: :ok

  def complete(scope, request_id, receipt, opts) when is_binary(request_id) do
    mutate(scope, request_id, opts, fn record ->
      %{record | "status" => "completed", "receipt" => receipt}
    end)
  end

  @doc """
  Drop a reservation that never started work.

  Succeeds only when the record is still `reserved` and the fingerprint matches.
  A missing, unknown, completed, or conflicting record is not released.
  """
  def release_reserved(scope, request_id, fingerprint, opts \\ [])

  def release_reserved(_scope, request_id, _fingerprint, _opts) when request_id in [nil, ""],
    do: :ok

  def release_reserved(scope, request_id, fingerprint, opts) when is_binary(request_id) do
    path = path(scope, opts)

    with_lock(path, fn ->
      case read_records(path) do
        {:error, :corrupt} ->
          {:error, :delivery_unknown}

        {:ok, records} ->
          case Map.get(records, request_id) do
            %{"fingerprint" => ^fingerprint, "status" => "reserved"} ->
              write_records_result(path, Map.delete(records, request_id))

            %{"fingerprint" => other} when other != fingerprint ->
              {:error, :idempotency_conflict}

            _ ->
              {:error, :not_reserved}
          end
      end
    end)
  end

  def mark_unknown(scope, request_id, opts \\ [])

  def mark_unknown(_scope, request_id, _opts) when request_id in [nil, ""], do: :ok

  def mark_unknown(scope, request_id, opts) when is_binary(request_id) do
    mutate(scope, request_id, opts, fn record ->
      %{record | "status" => "unknown", "receipt" => nil}
    end)
  end

  def lookup(scope, request_id, opts \\ []) when is_binary(request_id) do
    path = path(scope, opts)

    case read_records(path) do
      {:error, :corrupt} ->
        {:error, :corrupt}

      {:ok, records} ->
        case Map.get(records, request_id) do
          nil -> :error
          record -> {:ok, record}
        end
    end
  end

  def fingerprint(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
  end

  defp mutate(scope, request_id, opts, fun) do
    path = path(scope, opts)

    with_lock(path, fn ->
      case read_records(path) do
        {:error, :corrupt} ->
          {:error, :corrupt}

        {:ok, records} ->
          case Map.get(records, request_id) do
            nil ->
              :ok

            record ->
              write_records(path, Map.put(records, request_id, fun.(record)))
              :ok
          end
      end
    end)
  end

  defp with_lock(path, fun) do
    key = {__MODULE__, path}

    :global.trans({key, self()}, fn ->
      fun.()
    end)
  end

  defp path({kind, conversation_id}, opts) do
    root =
      Keyword.get(
        opts,
        :root,
        Application.get_env(
          :handbeam,
          :conversation_root,
          Path.join(Handbeam.Home.path(), ".handbeam/conversations")
        )
      )

    Path.join([root, "items", conversation_id, "operations-#{kind}.jsonl"])
  end

  defp drop_truncated_tail(content) do
    if String.ends_with?(content, "\n"),
      do: content,
      else: content |> String.split("\n") |> Enum.drop(-1) |> Enum.join("\n")
  end

  defp read_records(path) do
    case File.read(path) do
      {:ok, content} ->
        lines = content |> drop_truncated_tail() |> String.split("\n", trim: true)

        Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, acc} ->
          case Handbeam.JSON.decode(line) do
            {:ok, %{"request_id" => id} = record} when is_binary(id) ->
              {:cont, {:ok, Map.put(acc, id, record)}}

            _ ->
              {:halt, {:error, :corrupt}}
          end
        end)

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, _} ->
        {:error, :corrupt}
    end
  end

  defp receipt_write_fault do
    case Application.get_env(:handbeam, :operation_receipt_write_fault) do
      fun when is_function(fun, 0) ->
        case fun.() do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        :ok
    end
  end

  defp write_records(path, records) do
    case write_records_result(path, records) do
      :ok -> :ok
      {:error, reason} -> raise "operation receipt write failed: #{inspect(reason)}"
    end
  end

  defp write_records_result(path, records) do
    with :ok <- receipt_write_fault(),
         :ok <- mkdir_result(Path.dirname(path)) do
      body =
        Enum.map_join(Map.values(records), "\n", fn record ->
          record
          |> Map.put("$handbeam_operation", @version)
          |> Handbeam.JSON.encode!()
        end)

      tmp = path <> "." <> Integer.to_string(System.unique_integer([:positive])) <> ".tmp"

      with :ok <- file_result(File.write(tmp, body <> "\n")),
           :ok <- file_result(File.rename(tmp, path)) do
        :ok
      else
        {:error, _reason} = error ->
          File.rm(tmp)
          error
      end
    end
  end

  defp mkdir_result(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_result(:ok), do: :ok
  defp file_result({:error, reason}), do: {:error, reason}
end

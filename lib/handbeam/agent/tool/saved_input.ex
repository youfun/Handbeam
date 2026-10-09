defmodule Handbeam.Agent.Tool.SavedInput do
  @moduledoc """
  Immutable tool-input artifacts and reference retries.

  A failed write/edit stores the real input before any side effect. A later
  call may send `retry_of` plus a small override. The reference is resolved
  before path and approval checks, and a changed semantic field becomes a new
  revision. Cross-conversation references are rejected.
  """

  alias Handbeam.Agent.OperationReceipt

  @large_bytes 8_000
  @max_artifact_bytes 50_000_000

  @spec prepare(String.t(), map(), map(), [String.t()]) ::
          {:ok, map(), String.t()} | {:error, String.t(), map()}
  def prepare(tool, input, context, overridable) when is_map(input) do
    case Handbeam.Utils.SafeMap.get_any(input, "retry_of", :retry_of) do
      ref when is_binary(ref) and ref != "" ->
        resolve(tool, ref, input, context, overridable)

      _ ->
        save_fresh(tool, input, context)
    end
  end

  @spec attach(String.t(), term(), map(), [String.t()]) :: term()
  def attach(operation_id, outcome, context, allowed_overrides \\ ["file_path"])

  def attach(operation_id, {:error, reason}, context, allowed_overrides)
      when is_binary(operation_id) do
    if is_binary(conversation_id(context)) do
      failure(operation_id, to_string(reason), %{allowed_overrides: allowed_overrides})
    else
      {:error, to_string(reason)}
    end
  end

  def attach(_operation_id, other, _context, _allowed_overrides), do: other

  @spec failure(String.t(), String.t(), map()) :: {:error, String.t(), map()}
  def failure(operation_id, reason, extra \\ %{}) do
    {:error, reason,
     Map.merge(
       %{
         operation_id: operation_id,
         status: :failed,
         side_effect: :not_started,
         code: :input_rejected,
         recovery: %{
           action: :retry_saved_input,
           ref: operation_id,
           allowed_overrides: Map.get(extra, :allowed_overrides, [])
         }
       },
       extra
     )}
  end

  defp save_fresh(tool, input, context) do
    operation_id = "op_" <> Ecto.UUID.generate()

    case store_large_fields(tool, operation_id, input, context) do
      {:ok, stored} ->
        stored = Map.put(stored, "operation_id", operation_id)

        with :ok <- persist(tool, operation_id, stored, context) do
          {:ok, Map.put(input, "operation_id", operation_id), operation_id}
        end

      {:error, reason} ->
        failure(operation_id, reason, %{code: :artifact_unavailable, side_effect: :not_started})
    end
  end

  defp resolve(tool, ref, input, context, overridable) do
    with {:ok, saved} <- lookup(tool, ref, context) do
      overrides = Map.drop(input, ["retry_of", :retry_of, "operation_id", :operation_id])
      unknown = Enum.reject(Map.keys(overrides), &(to_string(&1) in overridable))

      cond do
        unknown != [] ->
          failure(ref, "retry_of only allows #{Enum.join(overridable, ", ")}", %{
            allowed_overrides: overridable,
            code: :invalid_retry
          })

        true ->
          merged = apply_overrides(saved, overrides)

          if semantic_change?(saved, merged, overridable) do
            save_fresh(tool, Map.drop(merged, ["operation_id", "retry_of"]), context)
          else
            {:ok, Map.put(merged, "operation_id", ref), ref}
          end
      end
    end
  end

  defp apply_overrides(saved, overrides) do
    Enum.reduce(overrides, saved, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp semantic_change?(saved, merged, overridable) do
    Enum.any?(overridable, fn key ->
      Map.get(saved, key) != Map.get(merged, key) and
        key in ["file_path", "old_string", "command"]
    end)
  end

  defp store_large_fields(tool, operation_id, input, context) do
    Enum.reduce_while(input, {:ok, input}, fn
      {key, value}, {:ok, acc} when is_binary(value) and byte_size(value) >= @large_bytes ->
        case write_artifact(tool, operation_id, to_string(key), value, context) do
          {:ok, ref} -> {:cont, {:ok, Map.put(acc, to_string(key), %{"__artifact__" => ref})}}
          :skip -> {:cont, {:ok, acc}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _pair, acc ->
        {:cont, acc}
    end)
  end

  defp write_artifact(_tool, _operation_id, _key, value, _context)
       when byte_size(value) > @max_artifact_bytes,
       do: {:error, "tool input exceeds the 50MB recovery artifact limit"}

  defp write_artifact(tool, operation_id, key, value, context) do
    conversation = conversation_id(context)

    if is_binary(conversation) do
      path = artifact_path(tool, conversation, operation_id, key, context)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, value) do
        {:ok, Path.basename(path)}
      else
        {:error, reason} -> {:error, "could not save tool input: #{inspect(reason)}"}
      end
    else
      :skip
    end
  end

  defp persist(tool, operation_id, stored, context) do
    conversation = conversation_id(context)

    if is_binary(conversation) do
      fingerprint = OperationReceipt.fingerprint({tool, stored})

      case OperationReceipt.reserve({:tool_input, conversation}, operation_id, fingerprint) do
        :ok ->
          :ok = OperationReceipt.complete({:tool_input, conversation}, operation_id, stored)
          :ok

        {:error, :idempotency_conflict} ->
          failure(operation_id, "saved input conflict", %{code: :idempotency_conflict})

        other ->
          failure(operation_id, "could not save tool input: #{inspect(other)}", %{
            code: :artifact_unavailable,
            side_effect: :not_started
          })
      end
    else
      :ok
    end
  end

  defp lookup(tool, ref, context) do
    conversation = conversation_id(context)

    if is_binary(conversation) do
      case OperationReceipt.lookup({:tool_input, conversation}, ref) do
        {:ok, %{"receipt" => receipt}} when is_map(receipt) ->
          materialize(tool, conversation, receipt, context)

        {:ok, _} ->
          failure(ref, "saved input has no receipt", %{code: :retry_not_found})

        _ ->
          failure(ref, "saved input was not found in this conversation", %{code: :retry_not_found})
      end
    else
      failure(ref, "retry_of requires a conversation", %{code: :retry_not_found})
    end
  end

  defp materialize(tool, conversation, receipt, context) do
    Enum.reduce_while(receipt, {:ok, %{}}, fn
      {key, %{"__artifact__" => name}}, {:ok, acc} when is_binary(name) ->
        path =
          artifact_path(
            tool,
            conversation,
            receipt["operation_id"] || ref_from(receipt),
            key,
            context
          )

        named = Path.join(Path.dirname(path), name)

        case File.read(named) do
          {:ok, body} ->
            {:cont, {:ok, Map.put(acc, key, body)}}

          {:error, reason} ->
            {:halt,
             failure(
               receipt["operation_id"] || "missing",
               "saved input artifact is unavailable",
               %{
                 code: :artifact_unavailable,
                 artifact_error: inspect(reason)
               }
             )}
        end

      {key, value}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, key, value)}}
    end)
  end

  defp artifact_path(tool, conversation, operation_id, key, context) do
    root =
      context[:tool_input_root] ||
        Application.get_env(
          :handbeam,
          :conversation_root,
          Path.join(Handbeam.Home.path(), ".handbeam/conversations")
        )

    Path.join([root, "items", conversation, "tool-inputs", tool, operation_id, key <> ".txt"])
  end

  defp ref_from(receipt), do: receipt["operation_id"] || "missing"

  defp conversation_id(context) do
    Handbeam.Utils.SafeMap.get_any(context, :conversation_id, "conversation_id")
  end
end

defmodule Handbeam.Agent.Tool.FileCommit do
  @moduledoc """
  Commit one workspace file through a same-directory temp file and a receipt.

  A crash before rename leaves the target untouched. A crash after rename but
  before the receipt is reconciled by the expected SHA: a matching target is
  committed and is not rewritten; a mismatch is unknown and is not overwritten.
  """

  alias Handbeam.Agent.OperationReceipt
  alias Handbeam.ChangeSnapshot

  @spec commit(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, String.t(), map()}
  def commit(path, content, context, opts \\ []) do
    path = follow_symlink(path)
    operation_id = Keyword.get(opts, :operation_id) || new_id()
    expected = ChangeSnapshot.sha256(content)
    receipt = %{"path" => path, "after_sha256" => expected, "operation_id" => operation_id}

    with :ok <- reserve(operation_id, receipt, context),
         :ok <- write_temp(path, content, operation_id),
         :ok <- File.rename(temp_path(path, operation_id), path),
         :ok <- complete(operation_id, receipt, context) do
      {:ok, %{operation_id: operation_id, after_sha256: expected, side_effect: :committed}}
    else
      {:replay, stored} ->
        {:ok,
         %{
           operation_id: operation_id,
           after_sha256: stored["after_sha256"],
           side_effect: :committed,
           replayed: true
         }}

      {:unknown, _} ->
        reconcile(path, expected, operation_id)

      {:error, reason} ->
        _ = File.rm(temp_path(path, operation_id))

        {:error, "file commit failed: #{inspect(reason)}",
         %{operation_id: operation_id, side_effect: :unknown, code: :commit_unknown}}
    end
  end

  @spec reconcile(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t(), map()}
  def reconcile(path, expected, operation_id) do
    case File.read(path) do
      {:ok, body} ->
        if ChangeSnapshot.sha256(body) == expected do
          {:ok,
           %{
             operation_id: operation_id,
             after_sha256: expected,
             side_effect: :committed,
             reconciled: true
           }}
        else
          {:error, "file commit is unknown and the target does not match; not overwriting",
           %{operation_id: operation_id, side_effect: :unknown, code: :commit_conflict}}
        end

      {:error, :enoent} ->
        {:error, "file commit did not start",
         %{operation_id: operation_id, side_effect: :not_started, code: :commit_not_started}}

      {:error, reason} ->
        {:error, "file commit could not be reconciled: #{inspect(reason)}",
         %{operation_id: operation_id, side_effect: :unknown, code: :commit_unknown}}
    end
  end

  defp write_temp(path, content, operation_id) do
    tmp = temp_path(path, operation_id)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(tmp, content)
    end
  end

  defp temp_path(path, operation_id) do
    safe = String.replace(operation_id, ~r/[^A-Za-z0-9_.-]/, "_")
    path <> "." <> safe <> ".tmp"
  end

  defp reserve(operation_id, receipt, context) do
    case conversation(context) do
      nil ->
        :ok

      conversation ->
        fingerprint = OperationReceipt.fingerprint(receipt)

        case OperationReceipt.reserve({:file_commit, conversation}, operation_id, fingerprint) do
          :ok -> :ok
          {:replay, stored} -> {:replay, stored}
          {:unknown, reason} -> {:unknown, reason}
          other -> other
        end
    end
  end

  defp complete(operation_id, receipt, context) do
    case conversation(context) do
      nil ->
        :ok

      conversation ->
        OperationReceipt.complete({:file_commit, conversation}, operation_id, receipt)
    end
  end

  defp follow_symlink(path) do
    case File.read_link(path) do
      {:ok, target} ->
        if Path.type(target) == :absolute,
          do: target,
          else: Path.expand(target, Path.dirname(path))

      _ ->
        path
    end
  end

  defp conversation(context), do: context[:conversation_id] || context["conversation_id"]
  defp new_id, do: "commit_" <> Integer.to_string(System.unique_integer([:positive]))
end

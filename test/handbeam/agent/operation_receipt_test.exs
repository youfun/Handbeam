defmodule Handbeam.Agent.OperationReceiptTest do
  use ExUnit.Case, async: false

  alias Handbeam.Agent.OperationReceipt

  setup do
    root = Path.join(System.tmp_dir!(), "receipt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "items/conv-receipt"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: [root: root]}
  end

  test "same id replays, different content conflicts, pending stays unknown", %{opts: opts} do
    scope = {:message, "conv-receipt"}
    fingerprint = OperationReceipt.fingerprint({"hello", :new_run})

    assert :ok = OperationReceipt.reserve(scope, "op-1", fingerprint, opts)
    assert :ok = OperationReceipt.complete(scope, "op-1", %{action: :started}, opts)

    assert {:replay, %{"action" => "started"}} =
             OperationReceipt.reserve(scope, "op-1", fingerprint, opts)

    assert {:error, :idempotency_conflict} =
             OperationReceipt.reserve(
               scope,
               "op-1",
               OperationReceipt.fingerprint("other"),
               opts
             )

    assert :ok = OperationReceipt.reserve(scope, "op-2", fingerprint, opts)

    assert {:unknown, :delivery_unknown} =
             OperationReceipt.reserve(scope, "op-2", fingerprint, opts)

    assert {:ok, %{"status" => "completed"}} = OperationReceipt.lookup(scope, "op-1", opts)
    assert {:ok, %{"status" => "unknown"}} = OperationReceipt.lookup(scope, "op-2", opts)
  end

  test "concurrent reserves of a new id accept one writer", %{opts: opts} do
    scope = {:message, "conv-receipt"}
    fingerprint = OperationReceipt.fingerprint({"race", :new_run})
    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          result = OperationReceipt.reserve(scope, "race-1", fingerprint, opts)
          send(parent, {:reserved, result})
          result
        end)
      end

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.all?(results -- [:ok], &(&1 == {:unknown, :delivery_unknown}))
  end

  test "a truncated tail is ignored and a reserved id stays unknown after reread", %{opts: opts} do
    scope = {:message, "conv-receipt"}
    fingerprint = OperationReceipt.fingerprint("partial")
    assert :ok = OperationReceipt.reserve(scope, "partial-1", fingerprint, opts)

    path = Path.join([opts[:root], "items", "conv-receipt", "operations-message.jsonl"])
    File.write!(path, File.read!(path) <> "{\"request_id\":\"torn\"")

    assert {:unknown, :delivery_unknown} =
             OperationReceipt.reserve(scope, "partial-1", fingerprint, opts)

    assert :error = OperationReceipt.lookup(scope, "torn", opts)
  end

  test "missing request id does not reserve", %{opts: opts} do
    assert :ok = OperationReceipt.reserve({:message, "conv"}, nil, "fp", opts)
    assert :error = OperationReceipt.lookup({:message, "conv"}, "missing", opts)
  end
end

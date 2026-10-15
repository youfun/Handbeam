defmodule Handbeam.StorageLockTest do
  use ExUnit.Case, async: false

  alias Handbeam.StorageLock

  setup do
    root = Path.join(System.tmp_dir!(), "handbeam-db-lock-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "holds one lock per resolved database path and releases it on shutdown", %{root: root} do
    database = Path.join(root, "handbeam.db")
    lock_path = StorageLock.lock_path(database)
    assert {:ok, pid} = StorageLock.start_link(database: database, name: nil)
    assert {:error, :locked} = :handbeam_storage.lock(lock_path)

    GenServer.stop(pid)

    assert {:ok, resource} = :handbeam_storage.lock(lock_path)
    assert :ok = :handbeam_storage.close(resource)
  end

  test "databases in the same directory have independent ownership", %{root: root} do
    first = Path.join(root, "handbeam.db")
    second = Path.join(root, "app.db")
    assert {:ok, first_owner} = StorageLock.start_link(database: first, name: nil)
    assert {:ok, second_owner} = StorageLock.start_link(database: second, name: nil)
    assert StorageLock.lock_path(first) != StorageLock.lock_path(second)
    GenServer.stop(first_owner)
    GenServer.stop(second_owner)
  end

  test "a second runtime gets a stable startup error", %{root: root} do
    database = Path.join(root, "handbeam.db")
    assert {:ok, owner} = StorageLock.start_link(database: database, name: nil)
    previous_flag = Process.flag(:trap_exit, true)
    assert {:error, :database_locked} = StorageLock.start_link(database: database, name: nil)
    Process.flag(:trap_exit, previous_flag)
    GenServer.stop(owner)
  end
end

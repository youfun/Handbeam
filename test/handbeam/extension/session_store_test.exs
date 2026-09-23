defmodule Handbeam.Extension.SessionStoreTest do
  use ExUnit.Case, async: false

  alias Handbeam.Extension.SessionStore

  describe "put/4 and get/4" do
    setup do
      session_id = "ext-test-#{System.unique_integer([:positive])}"
      dir = Path.join(System.tmp_dir!(), "sigil_ext_session_test_#{session_id}")

      on_exit(fn ->
        File.rm_rf(dir)
      end)

      # Start a Session process with a test store dir
      {:ok, _pid} =
        Handbeam.PubSub.Session.start_link(
          session_id: session_id,
          session_store_dir: dir,
          session_store_enabled?: true
        )

      on_exit(fn ->
        case Handbeam.PubSub.Session.whereis(session_id) do
          nil ->
            :ok

          pid ->
            try do
              GenServer.stop(pid, :normal, 5000)
            catch
              :exit, _ -> :ok
            end
        end
      end)

      %{session_id: session_id, dir: dir}
    end

    test "stores and retrieves extension state", %{session_id: sid} do
      assert SessionStore.get(sid, "goal", "focused_goal_id") == nil
      assert :ok = SessionStore.put(sid, "goal", "focused_goal_id", "m2x9k1f4")
      assert SessionStore.get(sid, "goal", "focused_goal_id") == "m2x9k1f4"
    end

    test "get returns default when key not found", %{session_id: sid} do
      assert SessionStore.get(sid, "goal", "missing", :default) == :default
    end

    test "different extensions have isolated state", %{session_id: sid} do
      :ok = SessionStore.put(sid, "goal", "key", "goal-val")
      :ok = SessionStore.put(sid, "other", "key", "other-val")
      assert SessionStore.get(sid, "goal", "key") == "goal-val"
      assert SessionStore.get(sid, "other", "key") == "other-val"
    end

    test "overwrites existing key", %{session_id: sid} do
      :ok = SessionStore.put(sid, "goal", "status", "active")
      :ok = SessionStore.put(sid, "goal", "status", "paused")
      assert SessionStore.get(sid, "goal", "status") == "paused"
    end
  end

  describe "get_all/2" do
    setup do
      session_id = "ext-all-#{System.unique_integer([:positive])}"
      dir = Path.join(System.tmp_dir!(), "sigil_ext_session_all_#{session_id}")

      on_exit(fn ->
        File.rm_rf(dir)
      end)

      {:ok, _pid} =
        Handbeam.PubSub.Session.start_link(
          session_id: session_id,
          session_store_dir: dir,
          session_store_enabled?: true
        )

      on_exit(fn ->
        case Handbeam.PubSub.Session.whereis(session_id) do
          nil ->
            :ok

          pid ->
            try do
              GenServer.stop(pid, :normal, 5000)
            catch
              :exit, _ -> :ok
            end
        end
      end)

      %{session_id: session_id}
    end

    test "returns all state for an extension", %{session_id: sid} do
      :ok = SessionStore.put(sid, "goal", "focused_goal_id", "abc")
      :ok = SessionStore.put(sid, "goal", "status", "active")
      :ok = SessionStore.put(sid, "other", "x", "y")

      all = SessionStore.get_all(sid, "goal")
      assert all == %{"focused_goal_id" => "abc", "status" => "active"}
    end

    test "returns empty map for extension with no state", %{session_id: sid} do
      assert SessionStore.get_all(sid, "nonexistent") == %{}
    end
  end

  describe "delete/3" do
    setup do
      session_id = "ext-del-#{System.unique_integer([:positive])}"
      dir = Path.join(System.tmp_dir!(), "sigil_ext_session_del_#{session_id}")

      on_exit(fn ->
        File.rm_rf(dir)
      end)

      {:ok, _pid} =
        Handbeam.PubSub.Session.start_link(
          session_id: session_id,
          session_store_dir: dir,
          session_store_enabled?: true
        )

      on_exit(fn ->
        case Handbeam.PubSub.Session.whereis(session_id) do
          nil ->
            :ok

          pid ->
            try do
              GenServer.stop(pid, :normal, 5000)
            catch
              :exit, _ -> :ok
            end
        end
      end)

      %{session_id: session_id}
    end

    test "deletes a key from extension state", %{session_id: sid} do
      :ok = SessionStore.put(sid, "goal", "x", "1")
      :ok = SessionStore.put(sid, "goal", "y", "2")
      assert :ok = SessionStore.delete(sid, "goal", "x")
      assert SessionStore.get(sid, "goal", "x") == nil
      assert SessionStore.get(sid, "goal", "y") == "2"
    end

    test "delete on non-existent key is no-op", %{session_id: sid} do
      assert :ok = SessionStore.delete(sid, "goal", "nonexistent")
    end
  end
end

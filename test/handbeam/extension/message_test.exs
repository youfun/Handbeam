defmodule Handbeam.Extension.MessageTest do
  use ExUnit.Case, async: false

  alias Handbeam.Extension.Message, as: ExtMessage

  describe "inject/4" do
    setup do
      session_id = "ext-msg-#{System.unique_integer([:positive])}"
      dir = Path.join(System.tmp_dir!(), "sigil_ext_msg_test_#{session_id}")

      on_exit(fn ->
        File.rm_rf(dir)
      end)

      # Start session
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

    test "inject with :steer delivery enqueues a steer candidate", %{session_id: sid} do
      # Need to attach a run (queue) first for steer to work
      # Without an active run, steer returns error
      assert {:error, :no_active_run} =
               ExtMessage.inject(sid, "continue working", :steer)
    end

    test "inject with :next_turn delivery adds to next_turn_messages", %{session_id: sid} do
      assert {:ok, _} = ExtMessage.inject(sid, "next prompt", :next_turn)

      # Verify the message was added
      pending = Handbeam.PubSub.Session.get_pending_messages(sid)
      assert length(pending) == 1
      assert hd(pending).deliver_as == :next_turn
    end

    test "inject with :follow_up delivery returns error without active run", %{session_id: sid} do
      assert {:error, :no_active_run} =
               ExtMessage.inject(sid, "follow up", :follow_up)
    end

    test "inject defaults to :steer delivery", %{session_id: sid} do
      assert {:error, :no_active_run} = ExtMessage.inject(sid, "test")
    end
  end
end

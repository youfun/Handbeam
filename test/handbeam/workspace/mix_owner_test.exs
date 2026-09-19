defmodule Handbeam.Workspace.MixOwnerTest do
  use ExUnit.Case, async: false

  alias Handbeam.Workspace.MixOwner

  setup do
    cwd = File.cwd!()
    env = System.get_env("MIX_HOME")

    on_exit(fn ->
      File.cd!(cwd)
      if env, do: System.put_env("MIX_HOME", env), else: System.delete_env("MIX_HOME")
    end)

    {:ok, cwd: cwd}
  end

  test "serializes work and restores cwd and env", %{cwd: cwd} do
    tmp = Path.join(System.tmp_dir!(), "sigil_mix_owner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    assert {:ok, :changed} =
             MixOwner.run(fn ->
               File.cd!(tmp)
               System.put_env("MIX_HOME", tmp)
               :changed
             end)

    assert File.cwd!() == cwd
    refute System.get_env("MIX_HOME") == tmp
    File.rm_rf!(tmp)
  end

  test "rejects overlapping runs", %{cwd: cwd} do
    parent = self()

    task =
      Task.async(fn ->
        MixOwner.run(fn ->
          send(parent, :started)
          Process.sleep(2_000)
          :done
        end)
      end)

    assert_receive :started, 1_000
    assert MixOwner.busy?()
    assert {:error, message, %{busy: true}} = MixOwner.run(fn -> :nope end)
    assert message =~ "another Mix project operation"
    assert :ok = MixOwner.cancel()
    assert {:error, _cancelled, %{cancelled: true}} = Task.await(task, 2_000)
    refute MixOwner.busy?()
    assert File.cwd!() == cwd
  end

  test "cancels a running operation and restores cwd", %{cwd: cwd} do
    parent = self()

    task =
      Task.async(fn ->
        MixOwner.run(
          fn ->
            send(parent, {:worker, self()})
            Process.sleep(10_000)
            :finished
          end,
          timeout_ms: 8_000
        )
      end)

    assert_receive {:worker, worker}, 1_000
    assert MixOwner.busy?()
    assert :ok = MixOwner.cancel()
    assert {:error, message, %{cancelled: true}} = Task.await(task, 2_000)
    assert message =~ "cancelled"
    refute Process.alive?(worker)
    refute MixOwner.busy?()
    assert File.cwd!() == cwd
  end

  test "cancellation waits for spawned work to terminate before releasing the owner" do
    parent = self()

    task =
      Task.async(fn ->
        MixOwner.run(fn ->
          child = spawn(fn -> receive do: (:finish -> send(parent, :child_finished)) end)
          send(parent, {:child, child})
          receive do: (:never -> :ok)
        end)
      end)

    assert_receive {:child, child}, 1_000
    assert Process.alive?(child)
    assert :ok = MixOwner.cancel()
    assert {:error, _message, %{cancelled: true}} = Task.await(task, 2_000)
    refute Process.alive?(child)
    refute MixOwner.busy?()
    refute_receive :child_finished, 50
    assert {:ok, :next_job} = MixOwner.run(fn -> :next_job end)
  end

  test "times out a running operation", %{cwd: cwd} do
    assert {:error, message, %{timed_out: true}} =
             MixOwner.run(fn -> Process.sleep(2_000) end, timeout_ms: 50)

    assert message =~ "timed out"
    refute MixOwner.busy?()
    assert File.cwd!() == cwd
  end

  test "timeout cleans spawned work before returning" do
    parent = self()

    assert {:error, _message, %{timed_out: true}} =
             MixOwner.run(
               fn ->
                 child = spawn(fn -> Process.sleep(:infinity) end)
                 send(parent, {:timeout_child, child})
                 Process.sleep(:infinity)
               end,
               timeout_ms: 50
             )

    assert_receive {:timeout_child, child}
    refute Process.alive?(child)
    refute MixOwner.busy?()
  end

  test "caller exit cleans the managed process tree" do
    parent = self()

    caller =
      spawn(fn ->
        MixOwner.run(fn ->
          child = spawn(fn -> Process.sleep(:infinity) end)
          send(parent, {:caller_exit_children, self(), child})
          Process.sleep(:infinity)
        end)
      end)

    assert_receive {:caller_exit_children, worker, child}, 1_000
    Process.exit(caller, :kill)

    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    refute Process.alive?(child)
    refute MixOwner.busy?()
  end

  test "repeated cancellation callers are released after cleanup" do
    parent = self()

    run =
      Task.async(fn ->
        MixOwner.run(fn ->
          send(parent, :repeat_cancel_started)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :repeat_cancel_started
    first = Task.async(fn -> MixOwner.cancel() end)
    second = Task.async(fn -> MixOwner.cancel() end)

    assert Task.await(first) == :ok
    assert Task.await(second) == :ok
    assert {:error, _message, %{cancelled: true}} = Task.await(run)
    refute MixOwner.busy?()
  end

  test "a successfully registered project remains workspace-owned when recompiled" do
    root =
      Path.join(
        System.tmp_dir!(),
        "sigil_owner_current_project_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    mix_file = Path.join(root, "mix.exs")

    File.write!(mix_file, """
    defmodule MixOwnerCurrentProject.MixProject do
      use Mix.Project
      def project, do: [app: :mix_owner_current_project, version: "0.1.0"]
    end
    """)

    try do
      assert {:ok, :registered} =
               MixOwner.run(fn -> :registered end, project_path: root)

      Code.compile_file(mix_file)
      assert {MixOwnerCurrentProject.MixProject, []} in :code.all_loaded()

      assert {:ok, host} =
               MixOwner.run(fn -> MixOwner.host_snapshot() end, project_path: root)

      refute MapSet.member?(host.modules, MixOwnerCurrentProject.MixProject)
    after
      :code.purge(MixOwnerCurrentProject.MixProject)
      :code.delete(MixOwnerCurrentProject.MixProject)
      File.rm_rf!(root)
    end
  end

  test "recovers after a raised failure", %{cwd: cwd} do
    assert {:error, message, %{raised: true}} =
             MixOwner.run(fn -> raise "mix-owner-boom" end)

    assert message =~ "mix-owner-boom"
    assert File.cwd!() == cwd
    assert {:ok, :ok} = MixOwner.run(fn -> :ok end)
  end
end

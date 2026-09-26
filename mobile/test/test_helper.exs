ExUnit.start()

defmodule HandbeamProbe.ScreenSettle do
  @moduledoc """
  Deliver the replies of `HandbeamProbe.HomeScreen` off-screen tasks to an
  in-BEAM `Mob.ScreenCase` view.

  Screen tasks run under `HandbeamProbe.TaskSupervisor` via
  `Task.Supervisor.async_nolink/2`, so their `{ref, result}` replies land in
  the test process (the screen's mailbox in-BEAM). `settle/1` feeds every
  reply back through `handle_info/2` and, while any task started by this
  process is still alive, blocks for the next one — no sleeps, no fixed
  waits, deterministic completion.
  """

  @timeout 5_000

  def settle(view) do
    receive do
      {ref, {tag, _generation, _result}} = msg when is_reference(ref) and is_atom(tag) ->
        settle(deliver(view, msg))

      {ref, {tag, _generation, _target, _result}} = msg when is_reference(ref) and is_atom(tag) ->
        settle(deliver(view, msg))
    after
      0 ->
        if pending_task?(), do: await(view), else: view
    end
  end

  defp await(view) do
    receive do
      {ref, {tag, _generation, _result}} = msg when is_reference(ref) and is_atom(tag) ->
        settle(deliver(view, msg))

      {ref, {tag, _generation, _target, _result}} = msg when is_reference(ref) and is_atom(tag) ->
        settle(deliver(view, msg))

      {:DOWN, _ref, :process, _pid, _reason} ->
        settle(view)
    after
      @timeout ->
        raise "screen task did not reply within #{@timeout}ms"
    end
  end

  defp deliver(%{socket: socket, module: module} = view, msg) do
    {:noreply, socket} = module.handle_info(msg, socket)
    %{view | socket: socket}
  end

  # A task this process is monitoring and that still runs under the screen's
  # Task.Supervisor. `:DOWN` handling above covers the exit-before-reply window.
  defp pending_task? do
    {:monitors, monitors} = Process.info(self(), :monitors)
    children = Task.Supervisor.children(HandbeamProbe.TaskSupervisor)
    Enum.any?(monitors, fn {:process, pid} -> pid in children end)
  end
end

unless Process.whereis(Handbeam.ExportSnapshot.Binding) do
  {:ok, _} = Handbeam.ExportSnapshot.Binding.start_link([])
end

data_dir =
  Path.join(System.tmp_dir!(), "handbeam_probe_test_#{System.unique_integer([:positive])}")

File.mkdir_p!(data_dir)
System.put_env("MOB_DATA_DIR", data_dir)

{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
{:ok, _} = Application.ensure_all_started(:handbeam)
:ok = HandbeamProbe.App.ensure_task_supervisor()
:ok = HandbeamProbe.ShareIntake.Lock.ensure_started()
:ok = HandbeamProbe.ShareCopy.ensure_started()
:ok = HandbeamProbe.Platform.IOS.Registry.ensure_started()
{:ok, _} = HandbeamProbe.Repo.start_link()

Ecto.Migrator.run(HandbeamProbe.Repo, :up, all: true)

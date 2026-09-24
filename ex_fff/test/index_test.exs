defmodule ExFff.IndexTest do
  use ExUnit.Case, async: false

  alias ExFff.Index

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "ex_fff_idx_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))

    File.write!(Path.join(tmp_dir, "lib/app.ex"), "module")
    File.write!(Path.join(tmp_dir, "lib/app_test.exs"), "module test")
    File.write!(Path.join(tmp_dir, "test/app_test.exs"), "module test")
    File.write!(Path.join(tmp_dir, "mix.exs"), "mix")
    File.write!(Path.join(tmp_dir, "config.exs"), "config")

    name = Module.concat(ExFff.Index, String.to_atom("Idx_#{System.unique_integer([:positive])}"))
    {:ok, pid} = Index.start_link(root_path: tmp_dir, name: name, max_files: 100)
    assert :ok = Index.await_index(name)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm_rf(tmp_dir)
    end)

    {:ok, pid: pid, name: name, tmp_dir: tmp_dir}
  end

  describe "start_link/1" do
    test "starts successfully with a valid root_path", %{pid: pid} do
      assert Process.alive?(pid)
    end

    test "rejects non-existent root_path" do
      # init returns {:stop, reason} for non-directory
      name =
        Module.concat(ExFff.Index, String.to_atom("Nope_#{System.unique_integer([:positive])}"))

      Process.flag(:trap_exit, true)

      result =
        try do
          Index.start_link(root_path: "/nonexistent/path/xyz", name: name)
        catch
          :exit, _reason -> {:error, :exit}
        end

      Process.flag(:trap_exit, false)

      # Either {:error, reason} or the linked process exits; both mean failure
      case result do
        {:error, _} ->
          assert true

        {:ok, pid} ->
          Process.sleep(10)
          refute Process.alive?(pid)
      end
    end
  end

  describe "search/3" do
    test "returns results with paths and scores", %{name: name} do
      {:ok, result} = Index.search(name, "app")
      assert is_list(result.paths)
      assert length(result.paths) > 0

      for entry <- result.paths do
        assert is_binary(entry.path)
        assert is_float(entry.score)
      end
    end

    test "empty query returns files", %{name: name} do
      {:ok, result} = Index.search(name, "*.ex")
      assert length(result.paths) > 0
    end
  end

  describe "touch/2" do
    test "touch updates frecency and affects ranking", %{name: name} do
      # Touch app.ex many times
      for _ <- 1..30, do: Index.touch(name, "lib/app.ex")

      {:ok, result} = Index.search(name, "app", limit: 3)
      paths = Enum.map(result.paths, & &1.path)

      assert "lib/app.ex" in paths
      # Should be ranked first due to high frecency
      assert hd(paths) == "lib/app.ex"
    end

    test "touch on non-existent path does not crash", %{name: name} do
      Index.touch(name, "nonexistent/path.ex")
      # Should not crash
      assert true
    end
  end

  describe "refresh/1" do
    test "refresh re-indexes files", %{name: name, tmp_dir: tmp_dir} do
      # Add a new file after initial index
      File.write!(Path.join(tmp_dir, "lib/new_file.ex"), "new")

      Index.refresh(name)
      assert :ok = Index.await_index(name)

      {:ok, result} = Index.search(name, "new")
      paths = Enum.map(result.paths, & &1.path)
      assert "lib/new_file.ex" in paths
    end
  end

  describe "scan limit" do
    test "max_files is a global cap, including a single large directory" do
      dir = Path.join(System.tmp_dir!(), "cap_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "wide"))

      for i <- 1..5 do
        File.write!(Path.join(dir, "wide/#{i}.ex"), "x")
      end

      File.mkdir_p!(Path.join(dir, "later"))
      File.write!(Path.join(dir, "later/extra.ex"), "x")

      config = ExFff.Config.new(root_path: dir, max_files: 3)
      paths = ExFff.Scanner.scan(dir, config)

      assert length(paths) == 3
      refute "later/extra.ex" in paths
      File.rm_rf(dir)
    end
  end

  describe "directory pruning" do
    test "prunes build, _build, deps, node_modules, and .gradle directories" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "ex_fff_prune_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(tmp_dir, "lib"))
      File.mkdir_p!(Path.join(tmp_dir, "build/outputs"))
      File.mkdir_p!(Path.join(tmp_dir, "_build/prod/lib"))
      File.mkdir_p!(Path.join(tmp_dir, "deps/phoenix"))
      File.mkdir_p!(Path.join(tmp_dir, "node_modules/react"))
      File.mkdir_p!(Path.join(tmp_dir, ".gradle/caches"))
      File.mkdir_p!(Path.join(tmp_dir, "mobile/android/app/build/intermediates"))

      File.write!(Path.join(tmp_dir, "lib/main.ex"), "main")
      File.write!(Path.join(tmp_dir, "build/outputs/app.apk"), "apk")
      File.write!(Path.join(tmp_dir, "_build/prod/lib/foo.beam"), "beam")
      File.write!(Path.join(tmp_dir, "deps/phoenix/phoenix.ex"), "phoenix")
      File.write!(Path.join(tmp_dir, "node_modules/react/index.js"), "react")
      File.write!(Path.join(tmp_dir, ".gradle/caches/cache.bin"), "bin")

      File.write!(
        Path.join(tmp_dir, "mobile/android/app/build/intermediates/classes.dex"),
        "dex"
      )

      name =
        Module.concat(ExFff.Index, String.to_atom("Prune_#{System.unique_integer([:positive])}"))

      {:ok, pid} = Index.start_link(root_path: tmp_dir, name: name)
      Index.await_index(pid)

      {:ok, counts} = GenServer.call(pid, :get_counts)
      # Only lib/main.ex should be indexed
      assert counts.files == 1

      {:ok, result} = Index.search(pid, "main")
      assert hd(result.paths).path == "lib/main.ex"

      {:ok, result_apk} = Index.search(pid, "app.apk")
      assert result_apk.paths == []

      {:ok, result_dex} = Index.search(pid, "classes.dex")
      assert result_dex.paths == []

      GenServer.stop(pid)
      File.rm_rf(tmp_dir)
    end
  end

  describe "workspace switching and multi-workspace" do
    test "get_root and set_root update workspace and re-index" do
      dir1 = Path.join(System.tmp_dir!(), "ws_1_#{System.unique_integer([:positive])}")
      dir2 = Path.join(System.tmp_dir!(), "ws_2_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)
      File.write!(Path.join(dir1, "project1_file.ex"), "p1")
      File.write!(Path.join(dir2, "project2_file.ex"), "p2")

      name =
        Module.concat(ExFff.Index, String.to_atom("Ws_#{System.unique_integer([:positive])}"))

      {:ok, pid} = Index.start_link(root_path: dir1, name: name)
      Index.await_index(pid)

      assert {:ok, ^dir1} = Index.get_root(pid)
      {:ok, res1} = Index.search(pid, "project1")
      assert length(res1.paths) == 1

      :ok = Index.set_root(pid, dir2)
      Index.await_index(pid)

      assert {:ok, ^dir2} = Index.get_root(pid)
      {:ok, res2} = Index.search(pid, "project2")
      assert length(res2.paths) == 1
      {:ok, res_old} = Index.search(pid, "project1")
      refute "project1_file.ex" in Enum.map(res_old.paths, & &1.path)

      GenServer.stop(pid)
      File.rm_rf(dir1)
      File.rm_rf(dir2)
    end

    test "ensure_started maintains separate indexes per workspace root" do
      dir_a = Path.join(System.tmp_dir!(), "multi_a_#{System.unique_integer([:positive])}")
      dir_b = Path.join(System.tmp_dir!(), "multi_b_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)
      File.write!(Path.join(dir_a, "alpha.ex"), "alpha")
      File.write!(Path.join(dir_b, "beta.ex"), "beta")

      {:ok, pid_a} = Index.ensure_started(dir_a)
      {:ok, pid_b} = Index.ensure_started(dir_b)

      assert pid_a != pid_b
      Index.await_index(pid_a)
      Index.await_index(pid_b)

      {:ok, res_a} = Index.search(pid_a, "alpha")
      assert length(res_a.paths) == 1
      assert hd(res_a.paths).path == "alpha.ex"

      {:ok, res_b} = Index.search(pid_b, "beta")
      assert length(res_b.paths) == 1
      assert hd(res_b.paths).path == "beta.ex"

      # Re-requesting dir_a returns the same pid_a
      assert {:ok, ^pid_a} = Index.ensure_started(dir_a)

      assert [{^pid_a, _}] = Registry.lookup(ExFff.Registry, Path.expand(dir_a))
      assert [{^pid_b, _}] = Registry.lookup(ExFff.Registry, Path.expand(dir_b))
      assert [_ | _] = DynamicSupervisor.which_children(ExFff.IndexSupervisor)

      GenServer.stop(pid_a)
      GenServer.stop(pid_b)
      File.rm_rf(dir_a)
      File.rm_rf(dir_b)
    end

    test "set_root replies to a search that was waiting on the old index" do
      dir1 = Path.join(System.tmp_dir!(), "cancel_1_#{System.unique_integer([:positive])}")
      dir2 = Path.join(System.tmp_dir!(), "cancel_2_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)
      File.write!(Path.join(dir1, "old_file.ex"), "old")
      File.write!(Path.join(dir2, "new_file.ex"), "new")

      name = Module.concat(ExFff.Index, String.to_atom("Cancel_#{System.unique_integer([:positive])}"))
      {:ok, pid} = Index.start_link(root_path: dir1, name: name)
      assert :ok = Index.await_index(pid)

      :sys.replace_state(pid, fn state -> %{state | status: :indexing} end)
      task = Task.async(fn -> Index.search(pid, "old", timeout: 2_000) end)
      Process.sleep(20)
      assert :ok = Index.set_root(pid, dir2)

      assert {:error, "index root changed"} = Task.await(task)
      assert :ok = Index.await_index(pid)
      {:ok, result} = Index.search(pid, "new")
      assert hd(result.paths).path == "new_file.ex"

      GenServer.stop(pid)
      File.rm_rf(dir1)
      File.rm_rf(dir2)
    end

    test "a failed scan stops the transient index and replies to waiters" do
      dir = Path.join(System.tmp_dir!(), "fail_idx_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "visible.ex"), "visible")

      name = Module.concat(ExFff.Index, String.to_atom("Fail_#{System.unique_integer([:positive])}"))
      {:ok, pid} = Index.start_link(root_path: dir, name: name)
      assert :ok = Index.await_index(pid)

      ref = Process.monitor(pid)
      task = Task.async(fn -> Index.await_index(pid, 2_000) end)
      :sys.replace_state(pid, fn state -> %{state | status: :indexing} end)
      Process.sleep(20)
      generation = :sys.get_state(pid).generation
      send(pid, {:index_failed, generation, :disk_failed})

      assert {:error, message} = Task.await(task)
      assert message =~ "Indexing failed"
      assert_receive {:DOWN, ^ref, :process, ^pid, {:indexing_failed, :disk_failed}}
      File.rm_rf(dir)
    end
  end
end

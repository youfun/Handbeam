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
    Process.sleep(50)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
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
      Process.sleep(20)

      Index.refresh(name)
      Process.sleep(50)

      {:ok, result} = Index.search(name, "new")
      paths = Enum.map(result.paths, & &1.path)
      assert "lib/new_file.ex" in paths
    end
  end
end

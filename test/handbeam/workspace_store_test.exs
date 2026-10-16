defmodule Handbeam.WorkspaceStoreTest do
  @moduledoc """
  Tests for Handbeam.WorkspaceStore — JSON-based workspace storage.

  Covers:
    - ensure_default!/0 creates default workspace
    - list when file missing returns default after ensure_default
    - add valid directory creates workspace
    - duplicate path does not duplicate and updates last_opened_at
    - invalid path returns error
    - file path returns error
    - dangerous root returns error
    - corrupted JSON returns error and does not crash
    - default workspace cannot be removed (if remove is implemented)
  """

  use ExUnit.Case, async: false

  alias Handbeam.WorkspaceStore

  setup do
    test_id = System.unique_integer([:positive])
    storage_path = Path.join(System.tmp_dir!(), "sigil_ws_store_test_#{test_id}.json")
    workspace_path = Path.join(System.tmp_dir!(), "sigil_ws_store_workspace_#{test_id}")
    previous_storage_path = System.get_env("HANDBEAM_WORKSPACES_FILE")
    previous_workspace_path = System.get_env("HANDBEAM_WORKSPACE")
    previous_config = Application.fetch_env(:handbeam, :workspaces_file)
    previous_host = Application.fetch_env(:handbeam, :host)

    System.put_env("HANDBEAM_WORKSPACES_FILE", storage_path)
    System.put_env("HANDBEAM_WORKSPACE", workspace_path)
    Application.put_env(:handbeam, :host, %{data_dir: workspace_path})

    if File.exists?(storage_path), do: File.rm!(storage_path)

    on_exit(fn ->
      restore_env("HANDBEAM_WORKSPACES_FILE", previous_storage_path)
      restore_env("HANDBEAM_WORKSPACE", previous_workspace_path)
      restore_config(:workspaces_file, previous_config)
      restore_config(:host, previous_host)
      if File.exists?(storage_path), do: File.rm!(storage_path)
      File.rm_rf!(workspace_path)
    end)

    {:ok, storage_path: storage_path, workspace_path: workspace_path}
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_config(key, {:ok, value}), do: Application.put_env(:handbeam, key, value)
  defp restore_config(key, :error), do: Application.delete_env(:handbeam, key)

  describe "storage_path/0" do
    test "returns the host's workspace file when no override is configured" do
      System.delete_env("HANDBEAM_WORKSPACES_FILE")
      Application.delete_env(:handbeam, :workspaces_file)
      expected = Handbeam.Home.expand("~/.handbeam/workspaces.json")
      assert WorkspaceStore.storage_path() == expected
    end

    test "test config isolates workspace metadata from the user's home" do
      System.delete_env("HANDBEAM_WORKSPACES_FILE")
      configured_path = Application.fetch_env!(:handbeam, :workspaces_file)

      assert WorkspaceStore.storage_path() == configured_path
      refute configured_path == Path.expand("~/.handbeam/workspaces.json")
      test_home = configured_path |> Path.dirname() |> Path.dirname()
      assert String.starts_with?(Path.basename(test_home), "handbeam_test_")
    end

    test "empty environment override uses application config", %{storage_path: storage_path} do
      System.put_env("HANDBEAM_WORKSPACES_FILE", "")
      Application.put_env(:handbeam, :workspaces_file, storage_path)

      assert WorkspaceStore.storage_path() == storage_path
    end

    test "uses HANDBEAM_WORKSPACES_FILE env var when set", %{storage_path: storage_path} do
      Application.put_env(:handbeam, :workspaces_file, storage_path <> ".other")
      assert WorkspaceStore.storage_path() == storage_path
    end
  end

  describe "ensure_default!/0" do
    test "creating a test default preserves the host's workspace index", %{
      workspace_path: workspace_path
    } do
      host_home = Path.join(workspace_path, "user-home")
      host_index = Path.join(host_home, ".handbeam/workspaces.json")
      isolated_index = Path.join(workspace_path, "test-data/workspaces.json")

      original =
        Jason.encode!(%{"workspaces" => [%{"id" => "default", "path" => "/user/project"}]})

      File.mkdir_p!(Path.dirname(host_index))
      File.write!(host_index, original)
      Application.put_env(:handbeam, :host, %{data_dir: host_home})
      Application.put_env(:handbeam, :workspaces_file, isolated_index)
      System.delete_env("HANDBEAM_WORKSPACES_FILE")

      expected_root = Path.join(host_home, ".handbeam/workspace")

      assert {:ok, %{"id" => "default", "path" => ^expected_root}} =
               WorkspaceStore.ensure_default!()

      assert File.read!(host_index) == original

      assert %{"workspaces" => [%{"path" => ^expected_root}]} =
               isolated_index |> File.read!() |> Jason.decode!()
    end

    test "creates default workspace when file does not exist", %{
      storage_path: storage_path,
      workspace_path: workspace_path
    } do
      refute File.exists?(storage_path)

      {:ok, ws} = WorkspaceStore.ensure_default!()

      assert ws["id"] == "default"
      assert ws["name"] == "My Workspace"
      assert ws["default"] == true
      assert ws["path"] == Path.join(workspace_path, ".handbeam/workspace")
      refute ws["path"] == workspace_path
      assert ws["added_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T/
      assert ws["last_opened_at"] =~ ~r/^\d{4}-\d{2}-\d{2}T/

      assert File.exists?(storage_path)
      assert File.exists?(Path.join(ws["path"], ".handbeam/settings.jsonc"))
    end

    test "repairs a default pointing to a project without moving its files", %{
      storage_path: storage_path,
      workspace_path: workspace_path
    } do
      File.mkdir_p!(workspace_path)
      marker = Path.join(workspace_path, "keep.txt")
      File.write!(marker, "existing project")

      existing = %{
        "id" => "default",
        "default" => true,
        "path" => workspace_path,
        "name" => "My Workspace",
        "added_at" => "original"
      }

      other = %{"id" => "project", "path" => workspace_path, "name" => "Project"}
      File.write!(storage_path, Jason.encode!(%{"workspaces" => [existing, other]}))

      assert {:ok, repaired} = WorkspaceStore.ensure_default!()
      assert repaired == Map.put(existing, "path", Handbeam.Workspace.default_root())
      assert {:ok, ^repaired} = WorkspaceStore.get("default")
      assert {:ok, ^other} = WorkspaceStore.get("project")
      assert File.read!(marker) == "existing project"
      assert {:ok, ^repaired} = WorkspaceStore.ensure_default!()
    end

    test "returns existing default workspace if file already has one" do
      {:ok, _ws1} = WorkspaceStore.ensure_default!()
      {:ok, _ws2} = WorkspaceStore.ensure_default!()

      workspaces = WorkspaceStore.list()
      # Should only have one default workspace
      assert length(workspaces) == 1
    end

    test "creates default workspace if file has no default entry" do
      json = ~s|{"workspaces": []}|
      File.write!(WorkspaceStore.storage_path(), json)

      {:ok, _ws} = WorkspaceStore.ensure_default!()
      workspaces = WorkspaceStore.list()
      assert length(workspaces) == 1
    end
  end

  describe "list/0" do
    test "returns default workspace when file missing after ensure_default", %{
      storage_path: storage_path
    } do
      refute File.exists?(storage_path)

      {:ok, _} = WorkspaceStore.ensure_default!()
      workspaces = WorkspaceStore.list()

      assert length(workspaces) == 1
      [ws] = workspaces
      assert ws["id"] == "default"
    end

    test "returns all workspaces" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      tmp_dir =
        Path.join(System.tmp_dir!(), "sigil_ws_store_list_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      try do
        {:ok, _} = WorkspaceStore.add(tmp_dir, name: "Test Project")
        workspaces = WorkspaceStore.list()

        assert length(workspaces) == 2
        ids = Enum.map(workspaces, & &1["id"])
        assert "default" in ids
      after
        if File.exists?(tmp_dir), do: File.rm_rf!(tmp_dir)
      end
    end
  end

  describe "add/2" do
    test "add valid directory creates workspace" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      tmp_dir =
        Path.join(System.tmp_dir!(), "sigil_ws_store_add_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      try do
        {:ok, ws} = WorkspaceStore.add(tmp_dir)
        assert ws["name"] == Path.basename(tmp_dir)
        assert ws["path"] == Path.expand(tmp_dir)
        assert ws["default"] == false
        assert ws["id"] != "default"
        assert length(WorkspaceStore.list()) == 2

        settings_path = Path.join(tmp_dir, ".handbeam/settings.jsonc")
        assert File.exists?(settings_path)
        assert File.read!(settings_path) =~ "\"eval\": false"
        refute File.exists?(Path.join(tmp_dir, ".handbeam/models.json"))
      after
        if File.exists?(tmp_dir), do: File.rm_rf!(tmp_dir)
      end
    end

    test "add can disable built-in memory for a new workspace" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_ws_store_memory_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      try do
        assert {:ok, _workspace} =
                 WorkspaceStore.add(tmp_dir, builtin_memory_enabled: false)

        refute Handbeam.WorkspaceSettings.builtin_memory_enabled(tmp_dir)

        assert {:ok, settings} = Handbeam.WorkspaceSettings.load(tmp_dir)
        assert get_in(settings, ["memory", "builtin_enabled"]) == false
      after
        if File.exists?(tmp_dir), do: File.rm_rf!(tmp_dir)
      end
    end

    test "add does not overwrite existing workspace settings" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "sigil_ws_store_policy_#{System.unique_integer([:positive])}"
        )

      settings_path = Path.join(tmp_dir, ".handbeam/settings.jsonc")
      File.mkdir_p!(Path.dirname(settings_path))
      existing_settings = ~s({"custom": true})
      File.write!(settings_path, existing_settings)

      try do
        assert {:ok, _ws} = WorkspaceStore.add(tmp_dir)
        assert File.read!(settings_path) == existing_settings
      after
        if File.exists?(tmp_dir), do: File.rm_rf!(tmp_dir)
      end
    end

    test "add with custom name" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      tmp_dir =
        Path.join(System.tmp_dir!(), "sigil_ws_store_add_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      try do
        {:ok, ws} = WorkspaceStore.add(tmp_dir, name: "My Custom Project")
        assert ws["name"] == "My Custom Project"
      after
        if File.exists?(tmp_dir), do: File.rm_rf!(tmp_dir)
      end
    end

    test "duplicate path does not duplicate and updates last_opened_at" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      tmp_dir =
        Path.join(System.tmp_dir!(), "sigil_ws_store_dup_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      try do
        {:ok, ws1} = WorkspaceStore.add(tmp_dir)
        Process.sleep(10)
        {:ok, ws2} = WorkspaceStore.add(tmp_dir)

        assert ws1["id"] == ws2["id"]
        assert length(WorkspaceStore.list()) == 2

        # last_opened_at should be updated
        assert ws2["last_opened_at"] >= ws1["last_opened_at"]
      after
        if File.exists?(tmp_dir), do: File.rm_rf!(tmp_dir)
      end
    end

    test "invalid path (non-existent) returns error" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      {:error, reason} = WorkspaceStore.add("/nonexistent/path/12345")
      assert reason =~ "exist" or reason =~ "not found"
    end

    test "file path returns error" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      {:error, reason} = WorkspaceStore.add(WorkspaceStore.storage_path())
      assert reason =~ "must be a directory" or reason =~ "not a directory"
    end

    test "dangerous root / returns error" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      {:error, reason} = WorkspaceStore.add("/")
      assert reason =~ "cannot be added"
    end

    test "dangerous root /etc returns error" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      {:error, reason} = WorkspaceStore.add("/etc")
      assert reason =~ "cannot be added"
    end

    test "dangerous root /System returns error" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      {:error, reason} = WorkspaceStore.add("/System")
      assert reason =~ "cannot be added"
    end

    test "dangerous root /bin returns error" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      {:error, reason} = WorkspaceStore.add("/bin")
      assert reason =~ "cannot be added"
    end

    test "dangerous root /sbin returns error" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      {:error, reason} = WorkspaceStore.add("/sbin")
      assert reason =~ "cannot be added"
    end

    test "dangerous root /usr returns error" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      {:error, reason} = WorkspaceStore.add("/usr")
      assert reason =~ "cannot be added"
    end

    test "dangerous root /var returns error" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      {:error, reason} = WorkspaceStore.add("/var")
      assert reason =~ "cannot be added"
    end

    test "expands tilde paths" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      tmp_dir =
        Path.join(System.tmp_dir!(), "sigil_ws_store_tilde_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      try do
        {:ok, ws} = WorkspaceStore.add(tmp_dir)
        assert ws["path"] == Path.expand(tmp_dir)
      after
        if File.exists?(tmp_dir), do: File.rm_rf!(tmp_dir)
      end
    end
  end

  describe "get/1" do
    test "returns workspace by id" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      tmp_dir =
        Path.join(System.tmp_dir!(), "sigil_ws_store_get_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      try do
        {:ok, ws} = WorkspaceStore.add(tmp_dir)
        assert {:ok, ^ws} = WorkspaceStore.get(ws["id"])
      after
        if File.exists?(tmp_dir), do: File.rm_rf!(tmp_dir)
      end
    end

    test "returns error for unknown id" do
      {:ok, _} = WorkspaceStore.ensure_default!()
      assert {:error, :not_found} = WorkspaceStore.get("nonexistent-id")
    end
  end

  describe "get_by_path/1" do
    test "returns workspace by path" do
      {:ok, _} = WorkspaceStore.ensure_default!()

      tmp_dir =
        Path.join(System.tmp_dir!(), "sigil_ws_store_gbp_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      try do
        {:ok, ws} = WorkspaceStore.add(tmp_dir)
        {:ok, found} = WorkspaceStore.get_by_path(Path.expand(tmp_dir))
        assert found["id"] == ws["id"]
      after
        if File.exists?(tmp_dir), do: File.rm_rf!(tmp_dir)
      end
    end

    test "returns error for unknown path" do
      {:ok, _} = WorkspaceStore.ensure_default!()
      assert {:error, :not_found} = WorkspaceStore.get_by_path("/nonexistent/workspace")
    end
  end

  describe "remove/1" do
    test "removes a non-default workspace without deleting its directory", %{
      workspace_path: workspace_path
    } do
      {:ok, _} = WorkspaceStore.ensure_default!()
      project_dir = Path.join(workspace_path, "extra")
      File.mkdir_p!(project_dir)
      File.write!(Path.join(project_dir, "keep.txt"), "kept")

      {:ok, added} = WorkspaceStore.add(project_dir, name: "Extra")
      assert {:ok, removed} = WorkspaceStore.remove(added["id"])
      assert removed["id"] == added["id"]
      assert {:error, :not_found} = WorkspaceStore.get(added["id"])
      assert File.read!(Path.join(project_dir, "keep.txt")) == "kept"
      assert Enum.map(WorkspaceStore.list(), & &1["id"]) == ["default"]
    end

    test "refuses to remove the default workspace" do
      {:ok, default} = WorkspaceStore.ensure_default!()
      assert {:error, :default_workspace} = WorkspaceStore.remove(default["id"])
      assert {:ok, _} = WorkspaceStore.get("default")
    end

    test "returns not found for an unknown id" do
      {:ok, _} = WorkspaceStore.ensure_default!()
      assert {:error, :not_found} = WorkspaceStore.remove("missing")
    end
  end

  describe "touch/1" do
    test "updates last_opened_at" do
      {:ok, ws} = WorkspaceStore.ensure_default!()
      Process.sleep(1100)

      {:ok, touched} = WorkspaceStore.touch(ws["id"])
      assert touched["last_opened_at"] >= ws["last_opened_at"]
    end

    test "returns error for unknown id" do
      {:ok, _} = WorkspaceStore.ensure_default!()
      assert {:error, :not_found} = WorkspaceStore.touch("nonexistent-id")
    end
  end

  describe "rename/2" do
    test "renames a workspace without changing its path", %{storage_path: _storage_path} do
      {:ok, _} = WorkspaceStore.ensure_default!()
      dir = Path.join(System.tmp_dir!(), "hb-rename-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      {:ok, ws} = WorkspaceStore.add(dir, name: "Old Name")
      assert {:ok, renamed} = WorkspaceStore.rename(ws["id"], "  New   Name  ")
      assert renamed["name"] == "New Name"
      assert renamed["path"] == Path.expand(dir)
      assert {:error, :empty} = WorkspaceStore.rename(ws["id"], "   ")
      assert {:error, :not_found} = WorkspaceStore.rename("missing", "Name")
    end
  end

  describe "corrupted JSON" do
    test "returns an error without overwriting the corrupted file", %{storage_path: storage_path} do
      corrupted = "this is not valid json {{{"
      File.write!(storage_path, corrupted)

      assert {:error, _reason} = WorkspaceStore.ensure_default!()
      assert File.read!(storage_path) == corrupted
    end
  end
end

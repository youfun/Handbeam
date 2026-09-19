defmodule HandbeamProbe.ShareWorkspaceImportTest do
  use ExUnit.Case, async: false

  alias HandbeamProbe.{ShareConfirm, ShareIntake, ShareWorkspaceImport}

  setup do
    dir = Path.join(System.tmp_dir!(), "share_ws_#{System.unique_integer([:positive])}")
    workspace_path = Path.join(dir, "workspace")
    intake_root = Path.join(dir, "share_intake")
    File.mkdir_p!(workspace_path)
    File.mkdir_p!(intake_root)
    previous_host = Application.get_env(:handbeam, :host)
    previous_root = Application.get_env(:handbeam_probe, :share_intake_root)
    Handbeam.Host.put!(%{data_dir: dir, shell: false, mcp: false})
    Application.put_env(:handbeam_probe, :share_intake_root, intake_root)

    on_exit(fn ->
      if previous_host,
        do: Application.put_env(:handbeam, :host, previous_host),
        else: Application.delete_env(:handbeam, :host)

      if previous_root,
        do: Application.put_env(:handbeam_probe, :share_intake_root, previous_root),
        else: Application.delete_env(:handbeam_probe, :share_intake_root)

      File.rm_rf!(dir)
    end)

    %{dir: dir, workspace: %{"path" => workspace_path}, intake_root: intake_root}
  end

  test "confirmation copies staged files and merges rather than sending", %{
    workspace: workspace,
    intake_root: intake_root
  } do
    id = Ecto.UUID.generate()
    source_dir = Path.join(intake_root, id)
    File.mkdir_p!(source_dir)
    source = Path.join(source_dir, "notes.md")
    File.write!(source, "shared notes")

    rec = %{
      "intake_id" => id,
      "subject" => "",
      "text" => "请总结",
      "files" => [
        %{
          "status" => "ready",
          "name" => "notes.md",
          "path" => source,
          "size" => 12
        }
      ]
    }

    assert {:ok, paths} = ShareWorkspaceImport.accept(rec, workspace)
    assert paths == [".handbeam/shared/#{id}/notes.md"]

    assert File.read!(Path.join(workspace["path"], ".handbeam/shared/#{id}/notes.md")) ==
             "shared notes"

    draft = ShareWorkspaceImport.merge_draft("已有草稿", rec, paths)
    assert draft =~ "已有草稿\n\n请总结"
    assert draft =~ ".handbeam/shared/#{id}/notes.md"
  end

  test "confirmation refuses a source path outside its staging request", %{
    dir: dir,
    workspace: workspace
  } do
    id = Ecto.UUID.generate()
    outside = Path.join(dir, "outside.txt")
    File.write!(outside, "do not import")

    rec = %{
      "intake_id" => id,
      "text" => "",
      "files" => [%{"status" => "ready", "name" => "outside.txt", "path" => outside}]
    }

    assert {:error, :copy_failed} = ShareWorkspaceImport.accept(rec, workspace)
    assert File.exists?(outside)
    refute File.exists?(Path.join(workspace["path"], ".handbeam/shared/#{id}"))
  end

  test "late success after cancel rolls back only owned dest", %{
    workspace: workspace,
    intake_root: intake_root
  } do
    id = Ecto.UUID.generate()
    user_file = Path.join(workspace["path"], "keep.txt")
    File.write!(user_file, "user")
    source_dir = Path.join(intake_root, id)
    File.mkdir_p!(source_dir)
    source = Path.join(source_dir, "notes.md")
    File.write!(source, "shared")

    write_fixture!(id, %{
      "state" => "cancelled",
      "consumption" => "workspace_copy",
      "text" => "x",
      "files" => [
        %{"status" => "ready", "name" => "notes.md", "path" => source, "size" => 6}
      ]
    })

    rec = elem(ShareIntake.get(id), 1)
    assert {:ok, _paths} = ShareWorkspaceImport.accept(rec, workspace)

    assert {:rollback, ^workspace, ^id, _} =
             ShareConfirm.finish_workspace(id, workspace, {:ok, [".handbeam/shared/#{id}/notes.md"]})

    assert {:ok, _} = ShareWorkspaceImport.schedule_rollback(workspace, id, notify: self())
    assert_receive {:share_rollback, ^id, :ok}, 1_000
    refute File.exists?(Path.join(workspace["path"], ".handbeam/shared/#{id}"))
    assert File.read!(user_file) == "user"
  end

  test "failed copy returns intake to review", %{workspace: workspace} do
    id = Ecto.UUID.generate()

    write_fixture!(id, %{
      "state" => "confirming",
      "consumption" => "workspace_copy",
      "workspace_path" => workspace["path"],
      "text" => "x",
      "files" => []
    })

    assert {:failed, _rec, ^workspace, ^id} =
             ShareConfirm.finish_workspace(id, workspace, {:error, :copy_failed})

    assert {:ok, _} = ShareConfirm.schedule_rollback(workspace, id, notify: self())
    assert_receive {:share_rollback, ^id, :ok}, 1_000
    assert {:ok, %{"state" => "pending_review"}} = ShareIntake.get(id)
  end

  defp write_fixture!(id, rec) do
    dir = Path.join(ShareIntake.root(), id)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "manifest.json"),
      Jason.encode!(Map.merge(%{"intake_id" => id}, rec))
    )
  end
end

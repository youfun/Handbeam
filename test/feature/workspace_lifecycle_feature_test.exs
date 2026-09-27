defmodule HandbeamWeb.Feature.WorkspaceLifecycleFeatureTest do
  @moduledoc """
  Adding, renaming, and removing a workspace updates the sidebar and the same
  workspace store. Removing a workspace does not delete its directory.

  Run: mix test --include e2e test/feature/workspace_lifecycle_feature_test.exs
  """

  use HandbeamWeb.FeatureCase, async: false

  alias Handbeam.TestSupport.E2EHarness
  alias Handbeam.WorkspaceStore

  import Phoenix.LiveViewTest, only: [render_click: 3]

  @moduletag :e2e

  test "add, rename, and remove stay consistent with the sidebar and store", %{conn: conn} do
    %{root: root} = E2EHarness.isolate_home!("workspace-lifecycle")
    project = Path.join(root, "project")
    File.mkdir_p!(project)
    File.write!(Path.join(project, "README.md"), "kept")

    page =
      conn
      |> visit("/")
      |> click_button("button[phx-click='open_add_project']", "+")
      |> unwrap(fn view ->
        render_click(view, "update_add_path", %{"value" => project})
        render_click(view, "update_add_name", %{"value" => "Lifecycle"})
      end)
      |> click_button("button[phx-click='confirm_add_project']", "Add Project")
      |> assert_has("#activity-bar", "Lifecycle", timeout: 2_000)

    workspace = Enum.find(WorkspaceStore.list(), &(&1["path"] == Path.expand(project)))
    assert workspace["name"] == "Lifecycle"
    refute workspace["default"]

    page =
      page
      |> unwrap(fn view ->
        render_click(view, "toggle_workspace_menu", %{"id" => workspace["id"]})
      end)
      |> unwrap(fn view ->
        render_click(view, "open_rename_workspace", %{"id" => workspace["id"]})
      end)
      |> assert_has("#rename-workspace-overlay", timeout: 2_000)
      |> fill_in("#rename-workspace-input", "工作区名称", with: "Renamed", exact: false)
      |> click_button("#rename-workspace-submit", "Save")
      |> assert_has("#activity-bar", "Renamed", timeout: 2_000)
      |> refute_has("#activity-bar", "Lifecycle")

    assert {:ok, renamed} = WorkspaceStore.get(workspace["id"])
    assert renamed["name"] == "Renamed"

    page
    |> unwrap(fn view ->
      render_click(view, "toggle_workspace_menu", %{"id" => workspace["id"]})
    end)
    |> click_button("#workspace-action-remove-#{workspace["id"]}", "Remove workspace")
    |> assert_has("#remove-workspace-overlay", timeout: 2_000)
    |> click_button("#confirm-remove-workspace", "Remove")
    |> refute_has("#workspace-group-#{workspace["id"]}", timeout: 2_000)

    refute Enum.any?(WorkspaceStore.list(), &(&1["id"] == workspace["id"]))
    assert File.read!(Path.join(project, "README.md")) == "kept"
  end
end

defmodule HandbeamWeb.WorkspaceTreeIconTest do
  use ExUnit.Case, async: true

  require Phoenix.LiveViewTest

  alias HandbeamWeb.WorkspaceLive.WorkspaceComponents

  test "directories and database files get distinct icons" do
    assert WorkspaceComponents.icon_type(%{kind: :directory, name: "scripts"}) == :directory
    assert WorkspaceComponents.icon_type(%{kind: :file, name: "handbeam_dev.db"}) == :database

    assert WorkspaceComponents.icon_type(%{kind: :file, name: "handbeam_test.db-wal"}) ==
             :database

    assert WorkspaceComponents.icon_type(%{kind: :symlink, name: "link"}) == :symlink
  end

  test "common source files keep their own marks" do
    assert WorkspaceComponents.file_icon_type("mix.exs") == :elixir
    assert WorkspaceComponents.file_icon_type("AGENTS.md") == :markdown
    assert WorkspaceComponents.file_icon_type(".gitignore") == :git
    assert WorkspaceComponents.file_icon_type("Dockerfile") == :config
    assert WorkspaceComponents.file_icon_type("notes.txt") == :file
  end

  test "tree icon renders an svg for the chosen type" do
    html =
      Phoenix.LiveViewTest.render_component(&WorkspaceComponents.tree_icon/1, type: :database)

    assert html =~ ~s(data-type="database")
    assert html =~ "<svg"
    refute html =~ "▧"
  end
end

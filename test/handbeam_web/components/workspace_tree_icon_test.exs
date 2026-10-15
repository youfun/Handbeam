defmodule HandbeamWeb.WorkspaceTreeIconTest do
  use ExUnit.Case, async: true

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
end

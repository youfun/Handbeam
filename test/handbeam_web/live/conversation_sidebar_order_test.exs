defmodule HandbeamWeb.WorkspaceLive.ConversationSidebarOrderTest do
  use ExUnit.Case, async: true

  require Phoenix.LiveViewTest

  alias HandbeamWeb.WorkspaceLive.ConversationState
  alias HandbeamWeb.WorkspaceLive.ConversationSwitching

  test "workspace sidebar lists the newest conversation first" do
    older = conversation("old", "2026-01-01T00:00:00Z")
    newer = conversation("new", "2026-09-28T00:00:00Z")

    ids =
      %{"ws" => [older, newer]}
      |> ConversationSwitching.workspace_conversations("ws", [%{"id" => "ws", "name" => "WS"}])
      |> Enum.map(& &1.id)

    assert ids == ["new", "old"]
  end

  test "free sidebar lists the newest conversation first" do
    older = conversation("old", "2026-01-01T00:00:00Z")
    newer = conversation("new", "2026-09-28T00:00:00Z")

    ids =
      %{ConversationSwitching.free_key() => [older, newer]}
      |> ConversationSwitching.free_conversations()
      |> Enum.map(& &1.id)

    assert ids == ["new", "old"]
  end

  test "reloading a selected conversation keeps its sidebar position" do
    older = conversation("old", "2026-01-01T00:00:00Z")
    newer = conversation("new", "2026-09-28T00:00:00Z")

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        conversations_by_workspace: %{"ws" => [older, newer]},
        chat_scope: :workspace,
        current_workspace_id: "ws",
        current_conversation_id: "old"
      }
    }

    reloaded = Map.put(older, "updated_at", "2026-12-01T00:00:00Z")
    socket = ConversationState.replace_current_conversation(socket, reloaded)

    ids =
      socket.assigns.conversations_by_workspace
      |> ConversationSwitching.workspace_conversations("ws", [%{"id" => "ws", "name" => "WS"}])
      |> Enum.map(& &1.id)

    assert ids == ["new", "old"]
  end

  test "tool modes appear for background and pinned conversations" do
    conv = conversation("background", "2026-01-01T00:00:00Z")

    pinned =
      conversation("pinned-background", "2026-01-01T00:00:00Z")
      |> Map.put("pinned_at", "2026-01-01T00:00:00Z")

    for mode <- [:run, :look, :edit] do
      html =
        Phoenix.LiveViewTest.render_component(
          &HandbeamWeb.WorkspaceLive.SidebarComponents.projects_sidebar/1,
          chat_scope: :workspace,
          collapsed_workspace_ids: MapSet.new(),
          conversation_menu_id: nil,
          conversations_by_workspace: %{"ws" => [conv, pinned]},
          current_conversation_id: "another-conversation",
          current_workspace_id: "ws",
          show_archive: false,
          workspaces: [%{"id" => "ws", "name" => "Workspace"}],
          runtime_tasks: %{
            tasks:
              Enum.map(
                ["background", "pinned-background"],
                &%{conversation_id: &1, status: :running, mode: mode}
              )
          }
        )

      nodes =
        Floki.find(
          Floki.parse_document!(html),
          "[data-run-id='background'], [data-run-id='pinned-background']"
        )

      assert length(nodes) == 2
      assert Floki.attribute(nodes, "data-run-mode") == [to_string(mode), to_string(mode)]
      assert Floki.attribute(nodes, "data-run-state") == ["running", "running"]
    end
  end

  defp conversation(id, updated_at) do
    %{
      "id" => id,
      "title" => id,
      "updated_at" => updated_at,
      "created_at" => updated_at,
      "workspace_id" => "ws"
    }
  end
end

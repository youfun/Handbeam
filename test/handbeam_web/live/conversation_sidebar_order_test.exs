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

  test "background and pinned indicators use only runtime status" do
    conv = conversation("background", "2026-01-01T00:00:00Z")

    pinned =
      conversation("pinned-background", "2026-01-01T00:00:00Z")
      |> Map.put("pinned_at", "2026-01-01T00:00:00Z")

    for status <- [:running, :waiting_confirmation, :idle] do
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
                &%{conversation_id: &1, status: status}
              )
          }
        )

      nodes =
        Floki.find(
          Floki.parse_document!(html),
          "[data-run-id='background'], [data-run-id='pinned-background']"
        )

      assert length(nodes) == 2
      assert Floki.attribute(nodes, "data-run-mode") == []
      assert Floki.attribute(nodes, "data-run-state") == [to_string(status), to_string(status)]
      assert Floki.find(nodes, ".run-tap-hand") == []
      assert length(Floki.find(nodes, ".run-arm-left")) == 2
      assert length(Floki.find(nodes, ".run-arm-right")) == 2

      stems = Floki.find(nodes, ".conversation-idle-stem")
      assert length(stems) == 2
      assert Floki.attribute(stems, "viewbox") == ["0 0 24 26", "0 0 24 26"]
      assert length(Floki.find(stems, ".idle-stem-fill")) == 2
      assert Floki.find(stems, ".run-leaf, .run-character, .run-leg-left, .run-leg-right") == []

      for node <- nodes do
        stem_paths = Floki.find([node], ".conversation-idle-stem path")
        leaf_paths = Floki.find([node], ".conversation-run-sprite .run-leaf path")
        assert Floki.attribute(stem_paths, "d") == Floki.attribute(leaf_paths, "d")
      end
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

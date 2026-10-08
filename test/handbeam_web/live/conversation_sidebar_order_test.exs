defmodule HandbeamWeb.WorkspaceLive.ConversationSidebarOrderTest do
  use ExUnit.Case, async: true

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

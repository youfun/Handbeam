defmodule HandbeamProbe.NativeHistoryTest do
  use ExUnit.Case, async: true
  use Gettext, backend: HandbeamProbe.Gettext
  alias HandbeamProbe.NativeHistory

  @now ~U[2026-09-10 12:00:00Z]
  @workspaces [%{"id" => "a", "name" => "Alpha"}, %{"id" => "b", "name" => "Beta"}]

  test "72 hour boundary, group ordering and hidden/deleted workspaces" do
    conversations = [
      conversation("a-new", "a", 0),
      conversation("b-new", "b", -60),
      conversation("boundary", "a", -72 * 3600),
      conversation("old-a", "a", -72 * 3600 - 1),
      conversation("old-b", "b", -80 * 3600),
      conversation("deleted", "gone", 0),
      Map.put(conversation("archived", "a", 0), "archived_at", "2026-09-10T12:00:00Z")
    ]

    history = NativeHistory.project(conversations, @workspaces, @now)
    assert Enum.map(history.recent, & &1.workspace["id"]) == ["free", "a", "b"]
    assert hd(history.recent).conversations == []
    alpha = Enum.find(history.recent, &(&1.workspace["id"] == "a"))
    assert Enum.map(alpha.conversations, & &1["id"]) == ["a-new", "boundary"]
    assert Enum.map(history.inactive, & &1.workspace["id"]) == ["a", "b"]
    assert history.inactive_count == 2

    closed = NativeHistory.render(history, false, "a-new")
    opened = NativeHistory.render(history, true, "a-new")
    refute Enum.any?(closed, &(&1.props[:text] == "old-a"))
    assert Enum.any?(opened, &(&1.props[:text] == "old-a"))
    assert Enum.any?(opened, &(&1.props[:text] == "old-b"))
  end

  test "missing timestamp remains reachable in inactive history" do
    history =
      NativeHistory.project([%{"id" => "unknown", "workspace_id" => "a"}], @workspaces, @now)

    assert Enum.map(history.recent, & &1.workspace["id"]) == ["free"]
    assert hd(history.recent).conversations == []
    assert history.inactive_count == 1
  end

  test "free chats are their own group, not a project" do
    conversations = [
      conversation("project", "a", 0),
      Map.merge(conversation("free-new", nil, -30), %{"scope" => "free"}),
      Map.merge(conversation("free-old", nil, -80 * 3600), %{"scope" => "free"})
    ]

    history = NativeHistory.project(conversations, @workspaces, @now)
    free = Enum.find(history.recent, &(&1.workspace["id"] == "free"))
    assert free.workspace["name"] == gettext("Chats")
    assert free.workspace["free"]
    assert Enum.map(free.conversations, & &1["id"]) == ["free-new"]
    assert Enum.map(history.recent, & &1.workspace["id"]) == ["free", "a"]
    refute Enum.any?(history.recent, &(&1.workspace["id"] == nil))

    inactive_free = Enum.find(history.inactive, &(&1.workspace["id"] == "free"))
    assert Enum.map(inactive_free.conversations, & &1["id"]) == ["free-old"]

    rendered = NativeHistory.render(history, false, nil)

    assert rendered
           |> Enum.flat_map(& &1.children)
           |> Enum.any?(&(&1.props[:id] == "new_free_chat"))

    refute Enum.any?(rendered, &(&1.props[:text] == "free-old"))
  end

  defp conversation(id, workspace, offset) do
    %{
      "id" => id,
      "title" => id,
      "workspace_id" => workspace,
      "updated_at" => @now |> DateTime.add(offset) |> DateTime.to_iso8601()
    }
  end
end

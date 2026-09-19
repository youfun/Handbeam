defmodule HandbeamProbe.NativeHistoryTest do
  use ExUnit.Case, async: true
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
    assert Enum.map(history.recent, & &1.workspace["id"]) == ["a", "b"]
    assert Enum.map(hd(history.recent).conversations, & &1["id"]) == ["a-new", "boundary"]
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

    assert history.recent == []
    assert history.inactive_count == 1
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

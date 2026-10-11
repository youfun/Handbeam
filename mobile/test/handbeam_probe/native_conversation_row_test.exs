defmodule HandbeamProbe.NativeConversationRowTest do
  use ExUnit.Case, async: true
  use Gettext, backend: HandbeamProbe.Gettext

  alias HandbeamProbe.{NativeConversationRow, NativeUI}

  @conversation %{"id" => "conv-1", "title" => "Ship the row", "pinned_at" => nil}

  test "row shows the title, a pixel bean, and menu actions only while open" do
    idle = nodes(@conversation, selected?: false, running?: false, menu_open?: false)
    running = nodes(@conversation, selected?: false, running?: true, menu_open?: false)
    menu = nodes(@conversation, selected?: false, running?: false, menu_open?: true)

    pinned =
      nodes(Map.put(@conversation, "pinned_at", "2026-10-09T00:00:00Z"),
        selected?: false,
        running?: false,
        menu_open?: true
      )

    assert text?(idle, "Ship the row")
    assert bean?(idle, "conv-1")
    assert bean_slot?(idle, "conv-1")
    assert bean_ink_x(idle) == 11
    refute menu_action?(idle)
    refute text?(idle, "●")

    assert bean?(running, "conv-1")
    assert eyes?(running)
    refute eyes?(idle)
    refute text?(running, "●")

    assert text?(menu, gettext("Pin"))
    assert text?(menu, gettext("Rename"))
    assert text?(menu, gettext("Archive"))
    assert menu_panel?(menu, "conv-1")
    assert tap?(menu, {:toggle_pin_conversation, "conv-1"})
    assert tap?(menu, {:rename_conversation, "conv-1"})
    assert tap?(menu, {:archive_conversation, "conv-1"})

    assert text?(pinned, gettext("Unpin"))
    refute text?(pinned, gettext("Pin"))
  end

  test "selected row uses the web active highlight and does not draw a bar" do
    selected = nodes(@conversation, selected?: true, running?: false, menu_open?: false)
    plain = nodes(@conversation, selected?: false, running?: false, menu_open?: false)

    refute text?(selected, "▍")
    refute text?(plain, "▍")
    assert title_color(selected) == control_argb(NativeUI.color(:ink))
    assert title_color(plain) == control_argb(NativeUI.color(:muted))
    assert title_weight(selected) == "medium"
    refute title_weight(plain)

    active = control_argb(NativeUI.color(:active))
    assert row_background(selected) == active
    assert row_background(plain) == control_argb(NativeUI.color(:surface))
    refute active == control_argb(NativeUI.color(:control))
  end

  test "rename field is shown only for the pending conversation" do
    pending = %{id: "conv-1", title: "Ship the row", error: "Name cannot be empty"}
    shown = nodes(@conversation, rename: pending)
    hidden = nodes(@conversation, rename: %{id: "other", title: "Elsewhere", error: nil})
    absent = nodes(@conversation, [])

    assert text?(shown, "Name cannot be empty")

    assert Enum.any?(
             flat(shown),
             &(&1.type == :text_field and &1.props[:value] == "Ship the row")
           )

    assert tap?(shown, {:confirm_rename_conversation, "Ship the row"})
    refute Enum.any?(flat(hidden), &(&1.type == :text_field))
    refute Enum.any?(flat(absent), &(&1.type == :text_field))
  end

  defp nodes(conversation, opts), do: NativeConversationRow.nodes(conversation, opts)

  defp flat(nodes), do: Enum.flat_map(nodes, &flatten/1)

  defp flatten(%{children: children} = node), do: [node | Enum.flat_map(children, &flatten/1)]
  defp flatten(node), do: [node]

  defp text?(nodes, text), do: Enum.any?(flat(nodes), &(&1.props[:text] == text))

  defp bean?(nodes, id) do
    Enum.any?(flat(nodes), fn node ->
      node.type == :canvas and node.props[:id] == "conversation-bean-#{id}"
    end)
  end

  defp bean_ink_x(nodes) do
    nodes
    |> flat()
    |> Enum.find(&(&1.type == :canvas and &1.props[:id] == "conversation-bean-conv-1"))
    |> then(fn node ->
      node.props[:draw]
      |> Enum.map(& &1[:x])
      |> Enum.min()
    end)
  end

  defp bean_slot?(nodes, id) do
    Enum.any?(flat(nodes), fn node ->
      node.type == :canvas and node.props[:id] == "conversation-bean-#{id}" and
        node.props[:width] == 24 and node.props[:height] == 26
    end)
  end

  defp eyes?(nodes) do
    Enum.any?(flat(nodes), fn node ->
      node.type == :canvas and
        Enum.any?(node.props[:draw] || [], fn op ->
          op[:op] == :rect and op[:color] == "#263b25" and op[:y] in [13, 14] and
            op[:x] in [8, 14]
        end)
    end)
  end

  defp menu_action?(nodes) do
    Enum.any?(
      [gettext("Pin"), gettext("Unpin"), gettext("Rename"), gettext("Archive")],
      &text?(nodes, &1)
    )
  end

  defp title_node(nodes) do
    Enum.find(flat(nodes), &(&1.props[:id] == "conversation-title-conv-1"))
  end

  defp title_color(nodes), do: title_node(nodes).props[:text_color]
  defp title_weight(nodes), do: title_node(nodes).props[:font_weight]

  defp row_background(nodes) do
    nodes
    |> flat()
    |> Enum.find(&(&1.props[:id] == "conversation-open-conv-1"))
    |> then(& &1.props[:background])
  end

  defp menu_panel?(nodes, id) do
    Enum.any?(flat(nodes), fn node ->
      node.type == :column and node.props[:id] == "conversation-menu-panel-#{id}" and
        node.props[:fill_width] == false and node.props[:corner_radius] == 8 and
        Enum.all?(node.children, &(&1.props[:fill_width] == false)) and
        weighted_spacer?(nodes, node)
    end)
  end

  defp weighted_spacer?(nodes, panel) do
    Enum.any?(flat(nodes), fn node ->
      node.type == :row and panel in node.children and
        Enum.any?(node.children, &(&1.type == :box and &1.props[:weight] == 1))
    end)
  end

  defp tap?(nodes, tag) do
    Enum.any?(flat(nodes), fn node ->
      match?({_, ^tag}, node.props[:on_tap])
    end)
  end

  defp control_argb("#" <> hex), do: String.to_integer("FF" <> hex, 16)
end

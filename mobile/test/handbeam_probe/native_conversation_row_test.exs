defmodule HandbeamProbe.NativeConversationRowTest do
  use ExUnit.Case, async: true
  use Gettext, backend: HandbeamProbe.Gettext

  alias HandbeamProbe.{NativeConversationRow, NativeUI}

  @conversation %{"id" => "conv-1", "title" => "Ship the row", "pinned_at" => nil}

  test "row shows the title, a running mark only while running, and menu actions only while open" do
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
    refute running_mark?(idle)
    refute menu_action?(idle)

    assert running_mark?(running)
    assert Enum.any?(flat(running), &(&1.props[:text] == "●" and &1.props[:text_size] == 11))

    assert text?(menu, gettext("Pin"))
    assert text?(menu, gettext("Rename"))
    assert text?(menu, gettext("Archive"))
    assert tap?(menu, {:toggle_pin_conversation, "conv-1"})
    assert tap?(menu, {:rename_conversation, "conv-1"})
    assert tap?(menu, {:archive_conversation, "conv-1"})

    assert text?(pinned, gettext("Unpin"))
    refute text?(pinned, gettext("Pin"))
  end

  test "selected row uses a light mark and does not fill with the control color" do
    selected = nodes(@conversation, selected?: true, running?: false, menu_open?: false)
    plain = nodes(@conversation, selected?: false, running?: false, menu_open?: false)

    assert text?(selected, "▍")
    refute text?(plain, "▍")

    control = NativeUI.color(:control)

    backgrounds =
      selected |> flat() |> Enum.map(& &1.props[:background]) |> Enum.reject(&is_nil/1)

    refute control in backgrounds
    refute control_argb(control) in backgrounds
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

  defp running_mark?(nodes) do
    Enum.any?(flat(nodes), fn node ->
      node.props[:text] == "●" and node.props[:text_size] == 11
    end)
  end

  defp menu_action?(nodes) do
    Enum.any?(
      [gettext("Pin"), gettext("Unpin"), gettext("Rename"), gettext("Archive")],
      &text?(nodes, &1)
    )
  end

  defp tap?(nodes, tag) do
    Enum.any?(flat(nodes), fn node ->
      match?({_, ^tag}, node.props[:on_tap])
    end)
  end

  defp control_argb("#" <> hex), do: String.to_integer("FF" <> hex, 16)
end

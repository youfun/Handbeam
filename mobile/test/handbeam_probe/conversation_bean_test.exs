defmodule HandbeamProbe.ConversationBeanTest do
  use ExUnit.Case, async: true

  # Rasterizer and pose. Inputs that must hold:
  # - "conv-1" hashes to the same palette slot as the web sidebar (266869767).
  # - An idle bean is only the leaf stem: no eye pixels.
  # - A running bean at frame 0 stands with eyes on y 14.
  # - Frame 2 is the first hop, so those eyes move to y 13.
  # - Waiting holds the standing pose instead of walking.
  # - A closed 1x2 rect path fills exactly those two pixels.

  alias HandbeamProbe.ConversationBean

  test "conversation color follows the web sidebar hash" do
    assert ConversationBean.color("conv-1") ==
             Enum.at(
               [
                 "#7eb8c9",
                 "#c9846a",
                 "#6a9a72",
                 "#8b7ec4",
                 "#c5a552",
                 "#c47d9b",
                 "#58aaa0",
                 "#6e94cc"
               ],
               rem(266_869_767, 8)
             )
  end

  test "idle stem stays put and a running bean hops" do
    idle = ConversationBean.canvas("conv-1", :idle)
    standing = ConversationBean.canvas("conv-1", :running, frame: 0)
    hopping = ConversationBean.canvas("conv-1", :running, frame: 2)
    waiting = ConversationBean.canvas("conv-1", :waiting, frame: 2)

    refute eye?(idle, 14)
    assert covers?(idle, 12, 10)
    assert eye?(standing, 14)
    assert eye?(standing, 15)
    refute eye?(standing, 13)
    assert eye?(hopping, 13)
    refute eye?(hopping, 15)

    assert draw(waiting) == draw(ConversationBean.canvas("conv-1", :waiting, frame: 9))
    refute draw(waiting) == draw(hopping)
  end

  defp draw(node), do: node.props[:draw]

  defp eye?(node, y) do
    Enum.any?(draw(node), fn op ->
      op[:color] == "#263b25" and op[:x] == 8 and op[:y] == y
    end)
  end

  defp covers?(node, x, y) do
    Enum.any?(draw(node), fn op ->
      op[:op] == :rect and op[:fill] == true and x >= op[:x] and x < op[:x] + op[:w] and
        y >= op[:y] and y < op[:y] + op[:h]
    end)
  end
end

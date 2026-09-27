defmodule HandbeamWeb.ConversationHoverTest do
  use ExUnit.Case, async: true

  alias HandbeamWeb.WorkspaceLive.{ConversationSwitching, ViewComponents}

  test "short relative time uses the compact hover format" do
    now = DateTime.utc_now()

    assert ViewComponents.short_relative_time(%{updated_at: iso(now, -30)}) == "now"
    assert ViewComponents.short_relative_time(%{updated_at: iso(now, -120)}) == "2m"
    assert ViewComponents.short_relative_time(%{updated_at: iso(now, -7_200)}) == "2h"
    assert ViewComponents.short_relative_time(%{updated_at: iso(now, -86_400 * 5)}) == "5d"
    assert ViewComponents.short_relative_time(%{updated_at: iso(now, -86_400 * 90)}) == "3mo"
    assert ViewComponents.short_relative_time(%{}) == ""
  end

  test "hover context uses the folder basename and omits a missing branch" do
    dir = Path.join(System.tmp_dir!(), "handbeam-hover-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    context =
      ConversationSwitching.hover_context(
        [%{"id" => "ws", "name" => "Ignored", "path" => dir}],
        "ws"
      )

    assert context.folder == Path.basename(dir)
    assert context.branch == nil
    assert ConversationSwitching.hover_context([], nil) == %{folder: nil, branch: nil}
  end

  defp iso(now, offset_seconds) do
    now |> DateTime.add(offset_seconds, :second) |> DateTime.to_iso8601()
  end
end

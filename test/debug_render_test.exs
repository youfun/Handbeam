defmodule DebugRenderTest do
  use HandbeamWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  # Copy helper from workspace_live_test
  defp session_id_from_html(html) do
    ids =
      Regex.scan(~r/data-session-id="([^"]*)"/, html, capture: :all_but_first)
      |> List.flatten()

    Enum.find(ids, &(&1 != "")) || List.last(ids) ||
      raise "no data-session-id in html"
  end

  setup do
    old_home = System.get_env("HOME")

    home_dir =
      Path.join(System.tmp_dir!(), "sigil_debug_home_#{System.unique_integer([:positive])}")

    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      if File.exists?(home_dir), do: File.rm_rf!(home_dir)
    end)

    :ok
  end

  test "debug render with isolate_home", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    IO.puts("--- HTML (first 500 chars) ---")
    IO.puts(String.slice(html, 0, 500))
    IO.puts("--- Looking for data-session-id ---")
    result = Regex.run(~r/data-session-id=(?:\"|')([^\"']+)(?:\"|')/, html)
    IO.inspect(result, label: "regex result")
    sid = session_id_from_html(html)
    IO.inspect(sid, label: "session_id")
  end
end

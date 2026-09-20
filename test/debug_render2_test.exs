defmodule DebugRender2Test do
  use HandbeamWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    old_home = System.get_env("HOME")

    home_dir =
      Path.join(System.tmp_dir!(), "handbeam_debug2_home_#{System.unique_integer([:positive])}")

    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
      if File.exists?(home_dir), do: File.rm_rf!(home_dir)
    end)

    :ok
  end

  test "debug full html", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    IO.puts("Has status-bar: #{String.contains?(html, "status-bar")}")
    IO.puts("Has data-session-id: #{String.contains?(html, "data-session-id")}")
    IO.puts("Has workspace-panel: #{String.contains?(html, "workspace-panel-header")}")
    IO.puts("HTML length: #{String.length(html)}")

    # Check for error patterns
    if String.contains?(html, "error") do
      IO.puts("HTML contains 'error'")
    end

    # Find body content
    body_start =
      case :binary.match(html, "<body") do
        {pos, _} -> pos
        :nomatch -> 0
      end

    IO.puts("Body starts at: #{body_start}")
    IO.puts(String.slice(html, body_start, 2000))
  end
end

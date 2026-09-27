defmodule HandbeamWeb.DesktopHealthControllerTest do
  use HandbeamWeb.ConnCase, async: true

  test "identifies a Handbeam backend to the desktop shell", %{conn: conn} do
    conn = get(conn, "/desktop-health")

    assert response(conn, 200) == "handbeam-desktop-health:v1"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end
end

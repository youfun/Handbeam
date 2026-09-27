defmodule HandbeamWeb.DesktopHealthController do
  @moduledoc false

  use HandbeamWeb, :controller

  @response "handbeam-desktop-health:v1"

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(200, @response)
  end
end

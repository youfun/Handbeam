defmodule HandbeamWeb.PageController do
  use HandbeamWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

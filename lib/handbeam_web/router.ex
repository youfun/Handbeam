defmodule HandbeamWeb.Router do
  use HandbeamWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug HandbeamWeb.Access
    plug :fetch_live_flash
    plug :put_root_layout, html: {HandbeamWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :put_locale
    plug :put_theme
  end

  # query param > SQLite preference > session > Accept-Language > default
  defp put_locale(conn, _opts) do
    conn = Plug.Conn.fetch_query_params(conn)

    locale =
      HandbeamWeb.Locale.resolve(
        conn.query_params,
        get_session(conn, :locale),
        List.first(get_req_header(conn, "accept-language"))
      )

    Gettext.put_locale(HandbeamWeb.Gettext, locale)
    put_session(conn, :locale, locale)
  end

  defp put_theme(conn, _opts) do
    assign(conn, :theme, Handbeam.Settings.UI.theme())
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HandbeamWeb do
    get "/desktop-health", DesktopHealthController, :show
  end

  scope "/", HandbeamWeb do
    pipe_through :browser

    live "/", WorkspaceLive, :index
    live "/c/:conversation_id", WorkspaceLive, :free
    live "/w/:workspace_id/c/:conversation_id", WorkspaceLive, :index
    live "/settings", SettingsLive, :index
    live "/settings/available-models", AvailableModelsLive, :index

    get "/uploads/:conversation_id/:file", UploadsController, :show

    get "/preview/:id", PreviewController, :show
    get "/preview/:id/files", PreviewController, :files
    get "/preview/:id/files/*path", PreviewController, :files
    get "/preview/:id/port", PreviewController, :port
    get "/preview/:id/port/*path", PreviewController, :port
  end

  # Other scopes may use custom stacks.
  # scope "/api", HandbeamWeb do
  #   pipe_through :api
  # end
end

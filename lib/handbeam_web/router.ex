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
  end

  # ── Locale 检测 ──
  # 优先级：query param > session > Accept-Language header > default (zh_CN)
  defp put_locale(conn, _opts) do
    conn = Plug.Conn.fetch_query_params(conn)

    default_locale =
      Application.get_env(:handbeam, HandbeamWeb.Gettext)[:default_locale] || "zh_CN"

    locale =
      case conn.query_params["locale"] do
        l when l in ["zh_CN", "en"] -> l
        _ -> get_session(conn, :locale) || parse_accept_language(conn) || default_locale
      end

    Gettext.put_locale(HandbeamWeb.Gettext, locale)
    conn |> put_session(:locale, locale)
  end

  defp parse_accept_language(conn) do
    case get_req_header(conn, "accept-language") do
      [header | _] ->
        header
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&parse_lang_tag/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> List.first()
        |> case do
          {lang, _q} when is_binary(lang) -> lang
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # zh-CN / zh / zh_CN → "zh_CN", en-US / en → "en"
  defp parse_lang_tag(tag) do
    case String.split(tag, ";", parts: 2) do
      [lang_range, q_str] ->
        with {lang, _} <- parse_lang_range(lang_range),
             {q, _} <- parse_q(q_str) do
          {lang, q}
        end

      [lang_range] ->
        {lang, _} = parse_lang_range(lang_range)
        {lang, 1.0}
    end
  end

  defp parse_lang_range(range) do
    range = String.trim(range)

    case String.split(range, "-", parts: 2) do
      ["zh"] -> {"zh_CN", ""}
      ["zh", _region] -> {"zh_CN", range}
      ["en"] -> {"en", ""}
      ["en", _region] -> {"en", range}
      [_lang] -> {"zh_CN", range}
      [lang, region] -> {"#{lang}_#{String.upcase(region)}", range}
    end
  end

  defp parse_q(q_str) do
    q_str = String.trim(q_str)

    case Regex.run(~r/^q=(\d+(?:\.\d+)?)$/i, q_str) do
      [_, q_val] -> {String.to_float(q_val), ""}
      _ -> {1.0, q_str}
    end
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HandbeamWeb do
    pipe_through :browser

    live "/", WorkspaceLive, :index
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

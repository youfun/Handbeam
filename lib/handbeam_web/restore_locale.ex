defmodule HandbeamWeb.RestoreLocale do
  @moduledoc """
  An `on_mount` hook to restore and apply the locale in LiveViews.
  """
  import Phoenix.Component

  def on_mount(:default, _params, session, socket) do
    default_locale =
      Application.get_env(:handbeam, HandbeamWeb.Gettext)[:default_locale] || "zh_CN"

    locale = Map.get(session, "locale") || default_locale
    Gettext.put_locale(HandbeamWeb.Gettext, locale)
    {:cont, assign(socket, :locale, locale)}
  end
end

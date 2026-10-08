defmodule HandbeamWeb.RestoreLocale do
  @moduledoc """
  An `on_mount` hook to restore and apply the locale in LiveViews.
  """
  import Phoenix.Component

  def on_mount(:default, params, session, socket) do
    params = if is_map(params), do: params, else: %{}
    locale = HandbeamWeb.Locale.resolve(params, Map.get(session, "locale"))
    Gettext.put_locale(HandbeamWeb.Gettext, locale)
    {:cont, assign(socket, :locale, locale)}
  end
end

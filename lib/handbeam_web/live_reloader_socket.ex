defmodule HandbeamWeb.LiveReloaderSocket do
  @moduledoc false

  use Phoenix.Socket, log: false

  channel "phoenix:live_reload", Phoenix.LiveReloader.Channel

  @impl Phoenix.Socket
  def connect(_params, socket, connect_info) do
    session = connect_info[:session] || %{}

    case HandbeamWeb.Access.mode() do
      :local ->
        if HandbeamWeb.Access.local_connect_info?(connect_info), do: {:ok, socket}, else: :error

      :password ->
        if HandbeamWeb.Access.authenticated_session?(session), do: {:ok, socket}, else: :error

      _invalid ->
        :error
    end
  end

  @impl Phoenix.Socket
  def id(_socket), do: nil
end

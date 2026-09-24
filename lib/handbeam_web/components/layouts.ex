defmodule HandbeamWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use HandbeamWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" height="36" alt="Handbeam" />
          <span class="text-sm font-semibold">v{Application.spec(:phoenix, :vsn)}</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-4 items-center">
          <li>
            <a href="https://phoenixframework.org/" class="btn btn-ghost">Website</a>
          </li>
          <li>
            <a href="https://github.com/phoenixframework/phoenix" class="btn btn-ghost">GitHub</a>
          </li>
          <li>
            <a href="https://hexdocs.pm/phoenix/overview.html" class="btn btn-primary">
              Get Started <span aria-hidden="true">&rarr;</span>
            </a>
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    info = Phoenix.Flash.get(assigns.flash, :info)
    error = Phoenix.Flash.get(assigns.flash, :error)

    assigns =
      assigns
      |> assign(:info, info)
      |> assign(:error, error)
      |> assign(:info_navigate, flash_navigate(info))
      |> assign(:error_navigate, flash_navigate(error))
      |> assign(:info_click, flash_click(info))
      |> assign(:error_click, flash_click(error))

    ~H"""
    <div id={@id} aria-live="polite">
      <.flash
        :if={@info_navigate}
        kind={:info}
        title={flash_title(@info)}
        navigate={@info_navigate}
        phx-click={@info_click}
      >
        {flash_body(@info)}
      </.flash>
      <.flash :if={!@info_navigate} kind={:info} flash={@flash} />
      <.flash
        :if={@error_navigate}
        kind={:error}
        title={flash_title(@error)}
        navigate={@error_navigate}
        phx-click={@error_click}
      >
        {flash_body(@error)}
      </.flash>
      <.flash :if={!@error_navigate} kind={:error} flash={@flash} />
    </div>
    """
  end

  defp flash_navigate(%{navigate: path}) when is_binary(path) and path != "", do: path
  defp flash_navigate(_), do: nil

  defp flash_click(%{navigate: path, navigate_with: :patch})
       when is_binary(path) and path != "" do
    JS.patch(path)
  end

  defp flash_click(%{navigate: path}) when is_binary(path) and path != "" do
    JS.navigate(path)
  end

  defp flash_click(_), do: nil

  defp flash_title(%{title: title}) when is_binary(title), do: title
  defp flash_title(_), do: nil

  defp flash_body(%{body: body}) when is_binary(body), do: body
  defp flash_body(message) when is_binary(message), do: message
end

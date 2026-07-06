defmodule VoyagerWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use VoyagerWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders the connect layout — bare full-screen wrapper with no application
  chrome. Used by the connection screen.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  def connect(assigns) do
    ~H"""
    {@inner_content}
    <.flash_group flash={@flash} />
    """
  end

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

  def app(assigns) do
    ~H"""
    <.flash_group flash={@flash} />
    <VoyagerWeb.Components.Shell.shell active_nav={assigns[:active_nav]} session={assigns[:session]}>
      {@inner_content}
    </VoyagerWeb.Components.Shell.shell>
    """
  end

  @doc """
  Renders the settings layout - a bare page with a topbar that
  shows a back arrow to the previous page. Used by the settings screen,
  reachable from both the connect panel and the app navbar.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  def settings(assigns) do
    ~H"""
    <.flash_group flash={@flash} />
    <div class="bg-base-100 flex h-screen flex-col overflow-hidden">
      <VoyagerWeb.Components.Shell.settings_topbar return_to={assigns[:return_to]} />
      <main class="flex-1 overflow-y-auto">
        {@inner_content}
      </main>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages to display"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="toast toast-top toast-end z-50" aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        "Attempting to reconnect"
        <.icon name="icon-rotate-cw" class="size-3 ml-1 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        "Attempting to reconnect"
        <.icon name="icon-rotate-cw" class="size-3 ml-1 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end

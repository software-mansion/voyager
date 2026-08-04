defmodule VoyagerWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use VoyagerWeb, :html

  embed_templates "layouts/*"

  alias Voyager.NodeSession.Session

  @doc """
  Renders the connect layout — bare full-screen wrapper with no application
  chrome. Used by the connection screen.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  def connect(assigns) do
    ~H"""
    {@inner_content}
    <.flash_group flash={@flash} />
    <.onboarding_modal show={assigns[:show_onboarding?]} />
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
  attr :session, Session, required: true

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  def app(assigns) do
    ~H"""
    <.flash_group flash={@flash} />
    <VoyagerWeb.Components.Shell.shell
      active_nav={assigns[:active_nav]}
      session={@session}
      mcp_status={assigns[:mcp_status]}
      current_url={assigns[:current_url]}
    >
      {@inner_content}
    </VoyagerWeb.Components.Shell.shell>
    <.onboarding_modal show={assigns[:show_onboarding?]} />
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
    <div class="bg-base-200 flex h-screen flex-col overflow-hidden">
      <VoyagerWeb.Components.Shell.settings_topbar return_to={assigns[:return_to]} />
      <main class="flex-1 overflow-y-auto">
        {@inner_content}
      </main>
    </div>
    <.onboarding_modal show={assigns[:show_onboarding?]} />
    """
  end

  @doc """
  Renders the first-launch popup informing users about anonymous telemetry
  collection and linking to the Terms of Service. Dismissed via the
  `"dismiss-onboarding"` event, handled by `VoyagerWeb.Hooks.OnboardingHook`.
  """
  attr :show, :boolean, default: false

  def onboarding_modal(assigns) do
    assigns = assign(assigns, :terms_of_service_url, Application.get_env(:voyager, :terms_of_service_url))

    ~H"""
    <div
      :if={@show}
      id="onboarding-modal"
      role="dialog"
      aria-modal="true"
      aria-labelledby="onboarding-modal-title"
      class="modal modal-open"
    >
      <div class="modal-box border-base-300 max-w-xl border shadow-2xl">
        <div class="mb-4 flex items-center gap-3">
          <div class="bg-info text-info-content rounded-box size-11 flex shrink-0 items-center justify-center">
            <.icon name="icon-info" class="size-5" />
          </div>
          <h2
            id="onboarding-modal-title"
            class="text-base-content text-lg font-semibold tracking-tight"
          >
            Help improve Voyager
          </h2>
        </div>

        <div class="text-base-content/70 flex flex-col gap-3 text-sm">
          <p>
            Voyager collects anonymous usage and diagnostic telemetry to help us improve the product.
          </p>
          <p>
            No data from your connected BEAM nodes is collected as part of this telemetry. You can disable telemetry at any time in <.link
              navigate={~p"/settings"}
              class="link link-primary"
            >Settings</.link>.
          </p>
          <p>
            By continuing, you acknowledge and agree to our <.link
              href={@terms_of_service_url}
              target="_blank"
              rel="noopener noreferrer"
              class="link link-primary"
            >
              Terms of Service
            </.link>.
          </p>
        </div>

        <div class="modal-action">
          <button
            type="button"
            id="onboarding-continue"
            phx-click="dismiss-onboarding"
            class="btn btn-primary"
          >
            Continue
          </button>
        </div>
      </div>
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

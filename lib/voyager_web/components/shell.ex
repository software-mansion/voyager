defmodule VoyagerWeb.Components.Shell do
  @moduledoc """
  App shell components - topbar, sidebar, content area, and status bar.

  The entry point is `shell/1`, which renders the full application chrome
  around a LiveView's inner content using daisyUI components (Navbar + Menu).
  The sidebar is always visible: icon-only ("compact") by default below the
  `lg` breakpoint and full width at `lg` and up, with a topbar button to
  override that default in either direction at any size.
  """

  use VoyagerWeb, :html

  alias Voyager.NodeSession.Session

  attr :active_nav, :atom, default: nil
  attr :session, Session, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="bg-base-200 flex h-screen flex-col overflow-hidden">
      <.topbar active_nav={@active_nav} session={@session} />

      <div class="relative flex flex-1 overflow-x-auto overflow-y-hidden">
        <.sidebar active_nav={@active_nav} session={@session} />

        <main class="min-w-xl relative flex-1 overflow-y-auto">
          {render_slot(@inner_block)}
        </main>
      </div>

      <.statusbar session={@session} />
    </div>
    """
  end

  attr :active_nav, :atom, default: nil
  attr :session, Session, default: nil

  defp topbar(assigns) do
    ~H"""
    <div class="navbar bg-base-100 border-base-300 min-h-14 z-10 flex-none gap-4 border-b px-4">
      <div class="navbar-start gap-2">
        <.brand />
      </div>
      <div class="navbar-end gap-1">
        <.theme_toggle />
        <%= if @session do %>
          <button
            type="button"
            phx-click="disconnect"
            title="Disconnect"
            class="btn btn-ghost btn-square btn-sm text-base-content/50 hover:text-error"
          >
            <.icon name="icon-log-out" class="size-4" />
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp theme_toggle(assigns) do
    ~H"""
    <div class="card border-base-300 bg-base-300 relative flex flex-row items-center rounded-full border-2">
      <div class="border-base-200 bg-base-100 [[data-theme=dark]_&]:left-1/2 transition-left absolute left-0 h-full w-1/2 rounded-full border brightness-110" />
      <button
        class="relative flex w-1/2 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title="Light"
      >
        <.icon name="icon-sun" class="size-4 opacity-75 hover:opacity-100" />
      </button>
      <button
        class="relative flex w-1/2 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        title="Dark"
      >
        <.icon name="icon-moon" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  defp brand(assigns) do
    ~H"""
    <div class="flex items-center gap-2.5 font-semibold tracking-tight">
      <.logo class="size-5.5" />
      <span class="text-lg">Voyager</span>
    </div>
    """
  end

  attr :active_nav, :atom, default: nil
  attr :session, Session, default: nil

  defp sidebar(assigns) do
    ~H"""
    <aside
      id="app-sidebar"
      class="bg-base-100 border-base-300 flex h-full w-16 flex-none flex-col overflow-y-auto overflow-x-hidden border-r transition-all duration-200 ease-out lg:w-64"
    >
      <ul class="menu font-sans w-full flex-1 gap-0.5 p-4">
        <li class="sidebar-toggle-row mb-3 flex flex-row items-center justify-between">
          <span class="menu-title sidebar-label tracking-label p-0 text-xs uppercase">Inspect</span>
          <button
            id="sidebar-compact-toggle"
            type="button"
            aria-label="Toggle sidebar width"
            class="btn btn-ghost btn-square btn-xs text-base-content/50 hover:text-base-content"
            phx-hook=".SidebarCompactToggle"
          >
            <.icon name="icon-panel-left" class="size-4" />
          </button>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".SidebarCompactToggle">
            export default {
              mounted() {
                this.el.addEventListener("click", () => {
                  const sidebar = document.getElementById("app-sidebar")
                  const isNarrowViewport = window.matchMedia("(max-width: 1023px)").matches
                  const isCompactNow =
                    sidebar.classList.contains("mode-compact") ||
                    (!sidebar.classList.contains("mode-full") && isNarrowViewport)

                  sidebar.classList.remove("mode-compact", "mode-full")
                  sidebar.classList.add(isCompactNow ? "mode-full" : "mode-compact")
                })
              }
            }
          </script>
        </li>
        <.nav_item active={@active_nav == :node_info} navigate={node_path(@session)} label="Node Info">
          <:icon><.icon name="icon-grid" class="size-4" /></:icon>
        </.nav_item>
        <.nav_item
          active={@active_nav == :supervision_tree}
          navigate={node_path(@session, "supervision-tree")}
          label="Supervision Tree"
        >
          <:icon><.icon name="icon-network" class="size-4" /></:icon>
        </.nav_item>
      </ul>
    </aside>
    """
  end

  attr :active, :boolean, default: false
  attr :navigate, :any, default: nil
  attr :label, :string, required: true
  slot :icon, required: true

  defp nav_item(%{navigate: nil} = assigns) do
    ~H"""
    <li class="pointer-events-none opacity-40">
      <span title={@label}>
        {render_slot(@icon)}
        <span class="sidebar-label truncate">{@label}</span>
      </span>
    </li>
    """
  end

  defp nav_item(assigns) do
    ~H"""
    <li>
      <.link navigate={@navigate} class={@active && "menu-active"} title={@label}>
        {render_slot(@icon)}
        <span class="sidebar-label truncate">{@label}</span>
      </.link>
    </li>
    """
  end

  defp node_path(nil), do: nil
  defp node_path(%Session{node_name: node_name}), do: ~p"/node/#{node_name}"

  defp node_path(nil, _), do: nil

  defp node_path(%Session{node_name: node_name}, "supervision-tree"),
    do: ~p"/node/#{node_name}/supervision-tree"

  attr :session, Session, default: nil

  defp statusbar(assigns) do
    ~H"""
    <footer class="border-base-300 bg-base-100 font-mono text-base-content/60 tracking-snug flex flex-none items-center gap-4 border-t px-4 py-1.5 text-xs">
      <div class="flex items-center gap-1.5">
        <span class={["h-1.5 w-1.5 rounded-full", status_dot_class(@session)]}></span>
        {node_display(@session)}
      </div>
      <div class="flex-1"></div>
      <div>v0.1.0</div>
    </footer>
    """
  end

  defp status_dot_class(nil), do: "bg-base-300"
  defp status_dot_class(%Session{}), do: "bg-success"

  defp node_display(nil), do: "Not connected"
  defp node_display(%Session{node_name: node_name}), do: node_name
end

defmodule VoyagerWeb.Components.Shell do
  @moduledoc """
  App shell components - topbar, sidebar, content area, and status bar.
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
      <.logo class="size-5.5 ml-[1px]" />
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
      phx-hook=".SidebarPersistedMode"
    >
      <script :type={Phoenix.LiveView.ColocatedHook} name=".SidebarPersistedMode">
        export default {
          mounted() {
            const savedMode = sessionStorage.getItem("sidebar-mode")
            if (savedMode === "compact" || savedMode === "full") {
              this.el.classList.add(`mode-${savedMode}`)
            }
          }
        }
      </script>
      <ul class="menu font-sans w-full flex-1 gap-0.5 p-4">
        <li class="sidebar-toggle-row mb-3 flex flex-row items-center justify-between">
          <span class="menu-title sidebar-label tracking-label p-0 text-xs uppercase">Inspect</span>
          <button
            id="sidebar-compact-toggle"
            type="button"
            aria-label="Toggle sidebar width"
            class="btn btn-ghost btn-square btn-sm text-base-content/50 hover:text-base-content"
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

                  const nextMode = isCompactNow ? "full" : "compact"
                  sidebar.classList.remove("mode-compact", "mode-full")
                  sidebar.classList.add(`mode-${nextMode}`)
                  sessionStorage.setItem("sidebar-mode", nextMode)
                })
              }
            }
          </script>
        </li>
        <%= for page <- inspect_pages() do %>
          <.nav_item
            active={@active_nav == page.feature}
            navigate={node_path(@session, page.path)}
            label={page.label}
          >
            <:icon><.icon name={page.icon} class="size-4" /></:icon>
          </.nav_item>
        <% end %>

        <%= for page <- coming_soon_pages() do %>
          <.nav_item
            active={@active_nav == page.feature}
            navigate={node_path(@session, page.path)}
            label={page.label}
            coming_soon
          >
            <:icon><.icon name={page.icon} class="size-4" /></:icon>
          </.nav_item>
        <% end %>
      </ul>
    </aside>
    """
  end

  @inspect_pages [
    %{feature: :node_info, path: nil, label: "Node Info", icon: "icon-grid"},
    %{
      feature: :supervision_tree,
      path: "supervision-tree",
      label: "Supervision Tree",
      icon: "icon-network"
    }
  ]

  @coming_soon_pages [
    %{feature: :processes, path: "processes", label: "Processes", icon: "icon-cpu"},
    %{
      feature: :ets_tables,
      path: "ets-tables",
      label: "ETS Tables",
      icon: "icon-database-search"
    },
    %{feature: :tracing, path: "tracing", label: "Tracing", icon: "icon-binoculars"},
    %{feature: :sockets, path: "sockets", label: "Sockets", icon: "icon-plug"},
    %{feature: :ports, path: "ports", label: "Ports", icon: "icon-ethernet-port"},
    %{feature: :charts, path: "charts", label: "Charts", icon: "icon-chart-column"},
    %{
      feature: :memory_allocators,
      path: "memory-allocators",
      label: "Memory Allocators",
      icon: "icon-memory-stick"
    }
  ]

  defp inspect_pages, do: @inspect_pages
  defp coming_soon_pages, do: @coming_soon_pages

  attr :active, :boolean, default: false
  attr :navigate, :any, default: nil
  attr :label, :string, required: true
  attr :coming_soon, :boolean, default: false
  slot :icon, required: true

  defp nav_item(%{navigate: nil} = assigns) do
    ~H"""
    <li class="pointer-events-none opacity-40">
      <span class="sidebar-nav-row" title={@label}>
        {render_slot(@icon)}
        <span class="sidebar-label flex-1 truncate">{@label}</span>
        <span :if={@coming_soon} class="sidebar-badge badge badge-soft badge-xs">Soon</span>
      </span>
    </li>
    """
  end

  defp nav_item(assigns) do
    ~H"""
    <li>
      <.link
        navigate={@navigate}
        class={["sidebar-nav-row", @active && "menu-active"]}
        title={@label}
      >
        {render_slot(@icon)}
        <span class="sidebar-label flex-1 truncate">{@label}</span>
        <span :if={@coming_soon} class="sidebar-badge badge badge-soft badge-xs">Soon</span>
      </.link>
    </li>
    """
  end

  defp node_path(nil, _), do: nil

  defp node_path(%Session{node_name: node_name}, nil),
    do: ~p"/node/#{node_name}"

defp node_path(%Session{node_name: node_name}, path),
  do: "/node/#{URI.encode(node_name)}/#{path}"

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

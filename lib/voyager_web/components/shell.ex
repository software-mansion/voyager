defmodule VoyagerWeb.Components.Shell do
  @moduledoc """
  App shell components - topbar, sidebar, content area, and status bar.
  """

  use VoyagerWeb, :html

  alias Voyager.NodeSession.Session

  attr :active_nav, :atom, default: nil
  attr :session, Session, required: true
  attr :current_path, :string, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="bg-base-200 flex h-screen flex-col overflow-hidden">
      <.topbar active_nav={@active_nav} session={@session} current_path={@current_path} />

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
  attr :session, Session, required: true
  attr :current_path, :string, default: nil

  defp topbar(assigns) do
    ~H"""
    <div class="navbar bg-base-100 border-base-300 min-h-14 z-10 flex-none gap-4 border-b px-4">
      <div class="navbar-start gap-2">
        <.brand />
      </div>
      <div class="navbar-end gap-1">
        <.link
          navigate={
            ~p"/settings?#{[return_to: settings_return_to(@active_nav, @session, @current_path)]}"
          }
          id="open-settings"
          title="Settings"
          class="btn btn-ghost btn-square btn-sm text-base-content/50 hover:text-base-content"
        >
          <.icon name="icon-settings" class="size-4" />
        </.link>
        <.theme_toggle />
        <button
          type="button"
          phx-click="disconnect"
          title="Disconnect"
          class="btn btn-ghost btn-square btn-sm text-base-content/50 hover:text-error"
        >
          <.icon name="icon-log-out" class="size-4" />
        </button>
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

  @doc """
  Renders the topbar used by the settings page — a back arrow to `return_to`
  (defaults to the connect page) followed by the brand mark.
  """
  attr :return_to, :string, default: nil

  def settings_topbar(assigns) do
    ~H"""
    <div class="navbar bg-base-100 border-base-300 min-h-14 z-10 flex-none gap-3 border-b px-4">
      <div class="navbar-start gap-3">
        <.link
          navigate={@return_to || ~p"/"}
          title="Back"
          class="btn btn-ghost btn-square text-base-content"
        >
          <.icon name="icon-arrow-left" class="size-6" />
        </.link>
        <.brand />
      </div>
    </div>
    """
  end

  defp brand(assigns) do
    ~H"""
    <div class="flex items-center gap-2.5 font-semibold tracking-tight">
      <.logo />
      <span class="text-lg">Voyager</span>
    </div>
    """
  end

  attr :active_nav, :atom, default: nil
  attr :session, Session, required: true

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
  attr :navigate, :any, required: true
  attr :label, :string, required: true
  slot :icon, required: true

  defp nav_item(assigns) do
    ~H"""
    <li>
      <.link
        navigate={@navigate}
        class={["sidebar-nav-row", @active && "menu-active"]}
        title={@label}
      >
        {render_slot(@icon)}
        <span class="sidebar-label truncate">{@label}</span>
      </.link>
    </li>
    """
  end

  defp node_path(session, path \\ nil)
  defp node_path(%Session{node_name: node_name}, nil), do: ~p"/node/#{node_name}"

  defp node_path(%Session{node_name: node_name}, "supervision-tree"),
    do: ~p"/node/#{node_name}/supervision-tree"

  defp settings_return_to(active_nav, session, current_path) do
    current_path || settings_return_to_fallback(active_nav, session)
  end

  defp settings_return_to_fallback(:supervision_tree, session),
    do: node_path(session, "supervision-tree")

  defp settings_return_to_fallback(_active_nav, session), do: node_path(session)

  attr :session, Session, required: true

  defp statusbar(assigns) do
    ~H"""
    <footer class="border-base-300 bg-base-100 font-mono text-base-content/60 tracking-snug flex flex-none items-center gap-4 border-t px-4 py-1.5 text-xs">
      <div class="flex items-center gap-1.5">
        <span class="bg-success h-1.5 w-1.5 rounded-full"></span>
        {@session.node_name}
      </div>
      <div class="flex-1"></div>
      <div>v0.1.0</div>
    </footer>
    """
  end
end

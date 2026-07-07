defmodule VoyagerWeb.Components.Shell do
  @moduledoc """
  App shell components - topbar, sidebar, content area, and status bar.

  The entry point is `shell/1`, which renders the full application chrome
  around a LiveView's inner content using daisyUI components (Navbar + Menu).
  The sidebar collapses into an off-canvas overlay below the `lg` breakpoint,
  toggled via a hamburger button and closed via backdrop click or nav-link click.
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

      <div class="relative flex flex-1 overflow-hidden">
        <.sidebar active_nav={@active_nav} session={@session} />

        <div
          id="app-sidebar-backdrop"
          class="bg-black/40 fixed inset-0 z-20 hidden lg:hidden"
          phx-click={close_sidebar()}
        >
        </div>

        <main class="relative flex-1 overflow-y-auto">
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
        <button
          type="button"
          aria-label="Toggle sidebar"
          class="btn btn-ghost btn-square btn-sm text-base-content/50 hover:text-base-content lg:hidden"
          phx-click={toggle_sidebar()}
        >
          <.icon name="icon-menu" class="size-4" />
        </button>
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
      class="bg-base-100 border-base-300 fixed inset-y-0 left-0 z-30 flex h-full w-64 flex-none -translate-x-full flex-col overflow-y-auto overflow-x-hidden border-r shadow-xl transition-transform duration-200 ease-out lg:static lg:z-auto lg:translate-x-0 lg:shadow-none"
    >
      <ul class="menu font-sans w-full flex-1 gap-0.5 p-4">
        <li class="menu-title tracking-label text-xs uppercase">Inspect</li>
        <.nav_item active={@active_nav == :node_info} navigate={node_path(@session)}>
          <:icon><.icon name="icon-grid" class="size-4" /></:icon>
          Node Info
        </.nav_item>
        <.nav_item
          active={@active_nav == :supervision_tree}
          navigate={node_path(@session, "supervision-tree")}
        >
          <:icon><.icon name="icon-network" class="size-4" /></:icon>
          Supervision Tree
        </.nav_item>
      </ul>
    </aside>
    """
  end

  attr :active, :boolean, default: false
  attr :navigate, :any, default: nil
  slot :icon, required: true
  slot :inner_block, required: true

  defp nav_item(%{navigate: nil} = assigns) do
    ~H"""
    <li class="pointer-events-none opacity-40">
      <span>
        {render_slot(@icon)}
        {render_slot(@inner_block)}
      </span>
    </li>
    """
  end

  defp nav_item(assigns) do
    ~H"""
    <li>
      <.link navigate={@navigate} class={@active && "menu-active"} phx-click={close_sidebar()}>
        {render_slot(@icon)}
        {render_slot(@inner_block)}
      </.link>
    </li>
    """
  end

  defp toggle_sidebar do
    JS.toggle_class("-translate-x-full", to: "#app-sidebar")
    |> JS.toggle_class("hidden", to: "#app-sidebar-backdrop")
  end

  defp close_sidebar do
    JS.add_class("-translate-x-full", to: "#app-sidebar")
    |> JS.add_class("hidden", to: "#app-sidebar-backdrop")
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

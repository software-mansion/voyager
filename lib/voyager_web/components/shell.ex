defmodule VoyagerWeb.Components.Shell do
  @moduledoc """
  App shell components - topbar, sidebar, content area, and status bar.

  The entry point is `shell/1`, which renders the full application chrome
  around a LiveView's inner content using daisyUI layout (Drawer + Navbar + Menu).
  """

  use VoyagerWeb, :html

  alias Voyager.NodeSession.Session

  attr :active_nav, :atom, default: nil
  attr :session, Session, default: nil
  attr :current_path, :string, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="bg-base-200 flex h-screen flex-col overflow-hidden">
      <.topbar active_nav={@active_nav} session={@session} current_path={@current_path} />

      <div class="flex flex-1 overflow-hidden">
        <.sidebar active_nav={@active_nav} session={@session} />

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
      <.logo class="size-5.5" />
      <span class="text-lg">Voyager</span>
    </div>
    """
  end

  attr :active_nav, :atom, default: nil
  attr :session, Session, default: nil

  defp sidebar(assigns) do
    ~H"""
    <aside class="bg-base-100 border-base-300 flex h-full w-64 flex-none flex-col overflow-y-auto overflow-x-hidden border-r">
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
      <.link navigate={@navigate} class={@active && "menu-active"}>
        {render_slot(@icon)}
        {render_slot(@inner_block)}
      </.link>
    </li>
    """
  end

  defp node_path(session, path \\ nil)
  defp node_path(nil, _path), do: nil
  defp node_path(%Session{node_name: node_name}, nil), do: ~p"/node/#{node_name}"

  defp node_path(%Session{node_name: node_name}, "supervision-tree"),
    do: ~p"/node/#{node_name}/supervision-tree"

  defp settings_return_to(active_nav, session, current_path) do
    current_path || settings_return_to_fallback(active_nav, session)
  end

  defp settings_return_to_fallback(:supervision_tree, session),
    do: node_path(session, "supervision-tree")

  defp settings_return_to_fallback(_active_nav, session), do: node_path(session) || "/"

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

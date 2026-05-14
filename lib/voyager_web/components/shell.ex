defmodule VoyagerWeb.Components.Shell do
  @moduledoc """
  App shell components — topbar, sidebar, content area, and status bar.

  The entry point is `shell/1`, which renders the full application chrome
  around a LiveView's inner content using daisyUI layout (Drawer + Navbar + Menu).
  """

  use VoyagerWeb, :html

  attr :active_nav, :atom, default: nil
  attr :node, :any, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="bg-base-100 flex h-screen flex-col overflow-hidden">
      <.topbar active_nav={@active_nav} />

      <div class="flex flex-1 overflow-hidden">
        <.sidebar active_nav={@active_nav} node={@node} />

        <main class="relative flex-1 overflow-y-auto">
          {render_slot(@inner_block)}
        </main>
      </div>

      <.statusbar node={@node} />
    </div>
    """
  end

  attr :active_nav, :atom, default: nil

  defp topbar(assigns) do
    ~H"""
    <div class="navbar bg-base-100 border-base-300 min-h-[3.5rem] z-10 flex-none gap-4 border-b px-4">
      <div class="navbar-start gap-2">
        <.brand />
      </div>
      <div class="navbar-end">
        <.link
          navigate={~p"/settings"}
          class={["btn btn-ghost btn-square btn-sm", @active_nav == :settings && "btn-active"]}
          title="Settings"
        >
          <.icon name="icon-settings" class="size-6" />
        </.link>
      </div>
    </div>
    """
  end

  defp brand(assigns) do
    ~H"""
    <div class="flex items-center gap-2.5 font-semibold tracking-tight">
      <div class="w-[22px] h-[22px] from-primary to-secondary rounded-[5px] shadow-[0_0_12px_color-mix(in_oklch,var(--color-primary)_25%,transparent)] relative shrink-0 bg-gradient-to-br">
        <div class="bg-base-100 rounded-[2px] shadow-[inset_0_0_0_1.5px_var(--color-primary)] absolute inset-1">
        </div>
      </div>
      <span class="text-[15px]">Voyager</span>
    </div>
    """
  end

  attr :active_nav, :atom, default: nil
  attr :node, :any, default: nil

  defp sidebar(assigns) do
    ~H"""
    <aside class="bg-base-100 border-base-300 flex h-full w-64 flex-none flex-col overflow-y-auto overflow-x-hidden border-r">
      <ul class="menu font-[var(--font-display)] w-full flex-1 gap-0.5 p-4">
        <li class="menu-title text-[10px] uppercase tracking-widest">Inspect</li>
        <.nav_item active={@active_nav == :node_info} navigate={node_path(@node)}>
          <:icon><.icon name="icon-grid" class="size-4" /></:icon>
          Node Info
        </.nav_item>
        <.nav_item
          active={@active_nav == :supervision_tree}
          navigate={node_path(@node, "supervision-tree")}
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

  defp node_path(nil), do: nil
  defp node_path(%Voyager.Node{name: name}), do: ~p"/node/#{name}"

  defp node_path(nil, _), do: nil

  defp node_path(%Voyager.Node{name: name}, "supervision-tree"),
    do: ~p"/node/#{name}/supervision-tree"

  attr :node, :any, default: nil

  defp statusbar(assigns) do
    ~H"""
    <footer class="border-base-300 bg-base-100 font-mono text-[10.5px] text-base-content/60 flex flex-none items-center gap-4 border-t px-4 py-1.5 tracking-wide">
      <div class="flex items-center gap-1.5">
        <span class={["h-1.5 w-1.5 rounded-full", status_dot_class(@node)]}></span>
        {node_display(@node)}
      </div>
      <div class="flex-1"></div>
      <div>v0.1.0</div>
    </footer>
    """
  end

  defp status_dot_class(nil), do: "bg-base-300"
  defp status_dot_class(%Voyager.Node{status: :connected}), do: "bg-success"
  defp status_dot_class(%Voyager.Node{status: :error}), do: "bg-error"
  defp status_dot_class(_), do: "bg-warning"

  defp node_display(nil), do: "Not connected"
  defp node_display(%Voyager.Node{name: name}), do: to_string(name)
end

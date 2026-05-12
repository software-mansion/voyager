defmodule VoyagerWeb.Components.Shell do
  @moduledoc """
  App shell components — topbar, sidebar, content area, and status bar.

  The entry point is `shell/1`, which renders the full application chrome
  around a LiveView's inner content. The sub-components (`topbar/1`,
  `sidebar/1`, `statusbar/1`) are private and composed inside `shell/1`.

  ## Usage

      <Shell.shell active_nav={:node_info} node={@node}>
        <p>Page content here</p>
      </Shell.shell>
  """

  use VoyagerWeb, :html

  attr :active_nav, :atom, default: nil
  attr :node, :string, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="app">
      <.topbar active_nav={@active_nav} />
      <div class="main">
        <.sidebar active_nav={@active_nav} node={@node} />
        <main class="content">
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
    <header class="topbar">
      <.brand />
      <div class="topbar-spacer"></div>
      <.link
        navigate={~p"/settings"}
        class={["icon-btn", @active_nav == :settings && "icon-btn--active"]}
        title="Settings"
      >
        <.icon name="icon-settings" class="size-3.5" />
      </.link>
    </header>
    """
  end

  defp brand(assigns) do
    ~H"""
    <div class="brand">
      <div class="brand-mark"></div>
      <span class="brand-name">Voyager</span>
    </div>
    """
  end

  attr :active_nav, :atom, default: nil
  attr :node, :string, default: nil

  defp sidebar(assigns) do
    ~H"""
    <aside class="sidebar">
      <div class="sidebar-section">
        <div class="sidebar-label">Inspect</div>
        <.nav_item
          active={@active_nav == :node_info}
          navigate={@node && ~p"/node/#{@node}"}
          tooltip="Node Info"
        >
          <:icon><.icon name="icon-grid" class="size-3.5" /></:icon>
          Node Info
        </.nav_item>
        <.nav_item
          active={@active_nav == :supervision_tree}
          navigate={@node && ~p"/node/#{@node}/supervision-tree"}
          tooltip="Supervision Tree"
        >
          <:icon><.icon name="icon-network" class="size-3.5" /></:icon>
          Supervision Tree
        </.nav_item>
      </div>
    </aside>
    """
  end

  attr :active, :boolean, default: false
  attr :navigate, :any, default: nil
  attr :tooltip, :string, default: nil
  slot :icon, required: true
  slot :inner_block, required: true

  defp nav_item(%{navigate: nil} = assigns) do
    ~H"""
    <span class={["nav-item", "nav-item--disabled", @active && "active"]} data-tooltip={@tooltip}>
      <span class="icon">{render_slot(@icon)}</span>
      <span class="nav-label">{render_slot(@inner_block)}</span>
    </span>
    """
  end

  defp nav_item(assigns) do
    ~H"""
    <.link navigate={@navigate} class={["nav-item", @active && "active"]} data-tooltip={@tooltip}>
      <span class="icon">{render_slot(@icon)}</span>
      <span class="nav-label">{render_slot(@inner_block)}</span>
    </.link>
    """
  end

  attr :node, :string, default: nil

  defp statusbar(assigns) do
    ~H"""
    <footer class="statusbar">
      <div class="item">
        <span class="dot"></span>
        {if @node, do: @node, else: "Not connected"}
      </div>
      <div class="spacer"></div>
      <div class="item">v0.1.0</div>
    </footer>
    """
  end
end

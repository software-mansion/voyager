defmodule VoyagerWeb.Components.Shell do
  @moduledoc """
  App shell components — topbar, sidebar, content area, and status bar.

  The entry point is `shell/1`, which renders the full application chrome
  around a LiveView's inner content.

  ## Usage

      <Shell.shell active_nav={:node_info} node={@node}>
        <p>Page content here</p>
      </Shell.shell>
  """

  use VoyagerWeb, :html

  attr :active_nav, :atom, default: nil
  attr :node, :any, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="app">
      <.topbar active_nav={@active_nav} />
      <div class="app-main">
        <.sidebar active_nav={@active_nav} node={@node} />
        <main class="app-content">
          {render_slot(@inner_block)}
        </main>
      </div>
      <.statusbar node={@node} />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Topbar
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Sidebar
  # ---------------------------------------------------------------------------

  attr :active_nav, :atom, default: nil
  attr :node, :any, default: nil

  defp sidebar(assigns) do
    ~H"""
    <aside class="sidebar">
      <div class="sidebar-section">
        <div class="sidebar-label">Inspect</div>
        <.nav_item
          active={@active_nav == :node_info}
          navigate={node_path(@node)}
        >
          <:icon><.icon name="icon-grid" class="size-3.5" /></:icon>
          Node Info
        </.nav_item>
        <.nav_item
          active={@active_nav == :supervision_tree}
          navigate={node_path(@node, "supervision-tree")}
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
  slot :icon, required: true
  slot :inner_block, required: true

  defp nav_item(%{navigate: nil} = assigns) do
    ~H"""
    <span class={["nav-item", "nav-item--disabled", @active && "nav-item--active"]}>
      <span class="nav-item-icon">{render_slot(@icon)}</span>
      <span class="nav-item-label">{render_slot(@inner_block)}</span>
    </span>
    """
  end

  defp nav_item(assigns) do
    ~H"""
    <.link navigate={@navigate} class={["nav-item", @active && "nav-item--active"]}>
      <span class="nav-item-icon">{render_slot(@icon)}</span>
      <span class="nav-item-label">{render_slot(@inner_block)}</span>
    </.link>
    """
  end

  defp node_path(nil), do: nil
  defp node_path(%Voyager.Node{name: name}), do: ~p"/node/#{name}"

  defp node_path(nil, _), do: nil

  defp node_path(%Voyager.Node{name: name}, "supervision-tree"),
    do: ~p"/node/#{name}/supervision-tree"

  # ---------------------------------------------------------------------------
  # Status bar
  # ---------------------------------------------------------------------------

  attr :node, :any, default: nil

  defp statusbar(assigns) do
    ~H"""
    <footer class="statusbar">
      <div class="statusbar-item">
        <span class={["statusbar-dot", status_dot_class(@node)]}></span>
        {node_display(@node)}
      </div>
      <div class="statusbar-spacer"></div>
      <div class="statusbar-item">v0.1.0</div>
    </footer>
    """
  end

  defp status_dot_class(nil), do: "statusbar-dot--off"
  defp status_dot_class(%Voyager.Node{status: :connected}), do: "statusbar-dot--good"
  defp status_dot_class(%Voyager.Node{status: :error}), do: "statusbar-dot--bad"
  defp status_dot_class(_), do: "statusbar-dot--warn"

  defp node_display(nil), do: "Not connected"
  defp node_display(%Voyager.Node{name: name}), do: to_string(name)
end

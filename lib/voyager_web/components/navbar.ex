defmodule VoyagerWeb.Components.Navbar do
  @moduledoc """
  Composable navbar and app-shell components.

  The primary entry point is `shell/1`, which renders the full application
  chrome (topbar, sidebar, content area, status bar) around a LiveView's
  inner content.

  ## Usage

      <Navbar.shell active_nav={:node_info} node={@node}>
        <p>Page content here</p>
      </Navbar.shell>
  """

  use VoyagerWeb, :html

  @doc """
  Renders the full application chrome: topbar, sidebar, content area, and
  status bar.

  ## Attributes

    * `:active_nav` — atom identifying the active sidebar item, e.g.
      `:node_info` or `:supervision_tree`. Defaults to `nil`.
    * `:node` — connected node name, e.g. `"myapp@localhost"`. When `nil`,
      node-scoped sidebar items are rendered as non-interactive placeholders.
      Defaults to `nil`.
  """
  attr :active_nav, :atom, default: nil
  attr :node, :string, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="app">
      <header class="topbar">
        <.brand />
        <div class="topbar-spacer"></div>
        <.link
          navigate={~p"/settings"}
          class={["icon-btn", @active_nav == :settings && "icon-btn--active"]}
          title="Settings"
        >
          <svg
            width="14"
            height="14"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
          >
            <circle cx="12" cy="12" r="3" />
            <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z" />
          </svg>
        </.link>
      </header>

      <div class="main">
        <aside class="sidebar">
          <div class="sidebar-section">
            <div class="sidebar-label">Inspect</div>
            <.nav_item
              active={@active_nav == :node_info}
              navigate={@node && ~p"/node/#{@node}"}
              tooltip="Node Info"
            >
              <:icon>
                <svg
                  width="14"
                  height="14"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                >
                  <rect x="3" y="3" width="7" height="7" /><rect x="14" y="3" width="7" height="7" />
                  <rect x="3" y="14" width="7" height="7" /><rect x="14" y="14" width="7" height="7" />
                </svg>
              </:icon>
              Node Info
            </.nav_item>
            <.nav_item
              active={@active_nav == :supervision_tree}
              navigate={@node && ~p"/node/#{@node}/supervision-tree"}
              tooltip="Supervision Tree"
            >
              <:icon>
                <svg
                  width="14"
                  height="14"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                >
                  <circle cx="6" cy="6" r="3" /><circle cx="18" cy="6" r="3" /><circle
                    cx="12"
                    cy="18"
                    r="3"
                  />
                  <path d="M6 9v6a3 3 0 0 0 3 3h6a3 3 0 0 0 3-3V9" />
                </svg>
              </:icon>
              Supervision Tree
            </.nav_item>
          </div>
        </aside>

        <main class="content">
          {render_slot(@inner_block)}
        </main>
      </div>

      <footer class="statusbar">
        <div class="item">
          <span class="dot"></span>
          {if @node, do: @node, else: "Not connected"}
        </div>
        <div class="spacer"></div>
        <div class="item">v0.1.0</div>
      </footer>
    </div>
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
end

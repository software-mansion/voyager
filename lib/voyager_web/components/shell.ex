defmodule VoyagerWeb.Components.Shell do
  @moduledoc """
  App shell components - topbar, sidebar, content area, and status bar.
  """

  use VoyagerWeb, :html

  alias Voyager.NodeSession.Session
  alias VoyagerWeb.Utils.URL

  attr :active_nav, :atom, default: nil
  attr :session, Session, required: true
  attr :mcp_status, :map, default: %{alive?: false, url: nil}
  attr :current_url, :string, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="bg-base-200 flex h-screen flex-col overflow-x-auto overflow-y-hidden">
      <div class="min-w-sm flex min-h-0 flex-1 flex-col">
        <.topbar
          active_nav={@active_nav}
          session={@session}
          mcp_status={@mcp_status}
          current_url={@current_url}
        />

        <div class="relative flex flex-1 overflow-y-hidden">
          <.sidebar
            active_nav={@active_nav}
            session={@session}
            mcp_status={@mcp_status}
            current_url={@current_url}
          />

          <main class="min-w-lg relative flex-1 overflow-y-auto">
            {render_slot(@inner_block)}
          </main>
        </div>
      </div>
    </div>
    """
  end

  attr :active_nav, :atom, default: nil
  attr :session, Session, required: true
  attr :mcp_status, :map, default: %{alive?: false, url: nil}
  attr :current_url, :string, default: nil

  defp topbar(assigns) do
    ~H"""
    <div class="bg-base-100 border-base-300 min-h-14 grid-cols-[auto_1fr_auto] z-10 grid flex-none items-center gap-4 border-b px-4">
      <.brand />
      <div class="@container/nav-status flex min-w-0">
        <.node_indicator session={@session} />
      </div>
      <.link
        href={~p"/settings?#{[return_to: settings_return_to(@active_nav, @session, @current_url)]}"}
        id="open-settings"
        title="Settings"
        class="btn btn-ghost btn-square toolbar-btn text-base-content/70 hover:text-base-content"
      >
        <.icon name="icon-settings" class="toolbar-icon" />
      </.link>
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
          href={@return_to || ~p"/"}
          title="Back"
          class="btn btn-ghost btn-square toolbar-btn text-base-content"
        >
          <.icon name="icon-arrow-left" class="toolbar-icon" />
        </.link>
        <.brand />
      </div>
    </div>
    """
  end

  defp brand(assigns) do
    assigns = assign(assigns, :version, Voyager.version())

    ~H"""
    <div class="flex items-center gap-2.5 font-semibold tracking-tight">
      <.logo class="size-5.5 ml-px" />
      <span class="text-lg">Voyager</span>
      <span class="font-mono text-base-content/70 mt-0.5 text-xs font-normal">v{@version}</span>
    </div>
    """
  end

  @feedback_url "https://github.com/software-mansion-labs/voyager-early-access-feedback/issues/new/choose"

  defp feedback_link(assigns) do
    assigns = assign(assigns, :feedback_url, @feedback_url)

    ~H"""
    <.tooltip id="sidebar-feedback-tip" position="top" class="w-full">
      <a
        id="sidebar-feedback"
        href={@feedback_url}
        target="_blank"
        rel="noopener noreferrer"
        aria-label="Feedback"
        class="sidebar-nav-row text-base-content/70 flex w-full items-center justify-start gap-2 rounded-md px-2 py-1.5 hover:text-base-content"
      >
        <.icon name="icon-message-square-share" class="toolbar-icon shrink-0" />
        <span class="sidebar-label font-mono truncate text-xs">Feedback</span>
      </a>
      <:content>Share your feedback with us here!</:content>
    </.tooltip>
    """
  end

  attr :status, :map, required: true
  attr :active_nav, :atom, default: nil
  attr :session, Session, required: true
  attr :current_url, :string, default: nil

  defp mcp_status_indicator(assigns) do
    ~H"""
    <.tooltip
      id={"mcp-status-tip-#{@status.alive?}-#{:erlang.phash2(@status.url)}"}
      interactive
      position="top"
      class="w-full"
    >
      <div
        id="mcp-status"
        class="sidebar-nav-row flex w-full cursor-default items-center justify-start gap-2 rounded-md px-2 py-1.5"
      >
        <span class="relative inline-flex shrink-0">
          <.icon name="icon-brain" class="text-base-content/70 size-4" />
          <span class="absolute -right-0.5 -bottom-0.5 flex h-1.5 w-1.5">
            <span
              :if={@status.alive?}
              class="bg-success absolute inline-flex h-full w-full animate-ping rounded-full opacity-75"
            >
            </span>
            <span class={[
              "relative inline-flex h-1.5 w-1.5 rounded-full",
              if(@status.alive?, do: "bg-success", else: "bg-error")
            ]}>
            </span>
          </span>
        </span>
        <span class="sidebar-label font-mono text-base-content/70 truncate text-xs">
          MCP {if @status.alive?, do: "running", else: "stopped"}
        </span>
      </div>
      <:content>
        <%= if @status.alive? do %>
          <div>
            <span>
              MCP server is running at
            </span>
            <div class="flex items-center gap-1">
              <span id="mcp-status-url" class="font-mono">{@status.url}</span>
              <.copy_button
                id="mcp-status-copy"
                target="#mcp-status-url"
                icon_only
                class="btn-xs text-base-content/70 shrink-0 hover:text-base-content"
              />
            </div>
          </div>
        <% else %>
          MCP server is not active. It can be enabled and configured in Settings.
          <.link
            href={
              ~p"/settings?#{[return_to: settings_return_to(@active_nav, @session, @current_url)]}"
            }
            class="text-primary mt-2 flex w-fit items-center gap-1 font-medium underline-offset-2 hover:underline"
          >
            Open Settings
          </.link>
        <% end %>
      </:content>
    </.tooltip>
    """
  end

  attr :active_nav, :atom, default: nil
  attr :session, Session, required: true
  attr :mcp_status, :map, default: %{alive?: false, url: nil}
  attr :current_url, :string, default: nil

  defp sidebar(assigns) do
    assigns = assign(assigns, :sidebar_mode, sidebar_mode(assigns.current_url))

    ~H"""
    <aside
      id="app-sidebar"
      class={[
        "bg-base-100 border-base-300 flex h-full flex-none flex-col overflow-y-auto overflow-x-hidden border-r transition-all duration-200 ease-out",
        @sidebar_mode == "compact" && "mode-compact",
        @sidebar_mode == "full" && "mode-full"
      ]}
    >
      <ul class="menu font-sans gap-1.75 w-full flex-1">
        <li class="sidebar-toggle-row mb-3 flex flex-row items-center justify-between">
          <span class="menu-title text-base-content/70 sidebar-label tracking-label p-0 text-xs uppercase">
            Inspect
          </span>
          <.sidebar_toggle current_url={@current_url} sidebar_mode={@sidebar_mode} />
        </li>
        <.nav_item
          :for={page <- inspect_pages()}
          active={@active_nav == page.feature}
          navigate={nav_path(node_path(@session, page.path), @sidebar_mode)}
          label={page.label}
        >
          <:icon><.icon name={page.icon} class="toolbar-icon" /></:icon>
        </.nav_item>

        <div class="border-base-content/10 my-4 border-t"></div>
        <span class="menu-title text-base-content/70 tracking-label mb-3 p-0 text-xs uppercase">
          Coming Soon
        </span>

        <.nav_item
          :for={page <- coming_soon_pages()}
          active={@active_nav == page.feature}
          navigate={nav_path(node_path(@session, page.path), @sidebar_mode)}
          label={page.label}
          coming_soon
        >
          <:icon><.icon name={page.icon} class="toolbar-icon" /></:icon>
        </.nav_item>
      </ul>

      <div class="mb-2.5 flex flex-none flex-col p-3 pb-0">
        <.feedback_link />
      </div>

      <div class="border-base-content/10 border-t mx-[length:var(--sidebar-compact-pad)]"></div>

      <div class="flex flex-none flex-col gap-1 p-3">
        <.mcp_status_indicator
          status={@mcp_status}
          active_nav={@active_nav}
          session={@session}
          current_url={@current_url}
        />
      </div>
    </aside>
    """
  end

  attr :current_url, :string, default: nil
  attr :sidebar_mode, :string, default: nil

  defp sidebar_toggle(assigns) do
    # Without an explicit mode the width is decided by CSS: compact below `lg`,
    # full from `lg` up. The server cannot know the viewport, so one toggle per
    # breakpoint is rendered and CSS reveals the one matching the current width.
    variants = [
      {"sidebar-compact-toggle", "lg:hidden", assigns.sidebar_mode || "compact"},
      {"sidebar-compact-toggle-wide", "max-lg:hidden", assigns.sidebar_mode || "full"}
    ]

    assigns = assign(assigns, :variants, variants)

    ~H"""
    <.link
      :for={{id, visibility, mode} <- @variants}
      id={id}
      patch={toggle_sidebar_path(@current_url, mode)}
      aria-label="Toggle sidebar width"
      class={[
        "btn btn-ghost btn-square toolbar-btn text-base-content/70 hover:text-base-content",
        visibility
      ]}
    >
      <.icon name="icon-panel-left" class="toolbar-icon" />
    </.link>
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
        <span :if={@coming_soon} class="sidebar-badge badge badge-primary badge-soft badge-xs">
          Soon
        </span>
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
        <span :if={@coming_soon} class="sidebar-badge badge badge-primary badge-soft badge-xs">
          Soon
        </span>
      </.link>
    </li>
    """
  end

  defp node_path(session, path \\ nil)
  defp node_path(%Session{node_name: node_name}, nil), do: ~p"/node/#{node_name}"

  defp node_path(%Session{node_name: node_name}, path),
    do: "/node/#{URI.encode(node_name)}/#{path}"

  defp sidebar_mode(url) when is_binary(url) do
    case URL.get_query_param(url, "sidebar") do
      mode when mode in ["compact", "full"] -> mode
      _ -> nil
    end
  end

  defp sidebar_mode(_url), do: nil

  # Carries the current sidebar mode onto a nav link so the choice survives
  # navigation to another page.
  defp nav_path(path, mode) when mode in ["compact", "full"],
    do: URL.put_query_param(path, "sidebar", mode)

  defp nav_path(path, _mode), do: path

  defp toggle_sidebar_path(current_url, sidebar_mode) do
    next_mode = if sidebar_mode == "compact", do: "full", else: "compact"
    URL.put_query_param(current_url || "/", "sidebar", next_mode)
  end

  defp settings_return_to(active_nav, session, current_url) do
    current_url || settings_return_to_fallback(active_nav, session)
  end

  defp settings_return_to_fallback(:supervision_tree, session),
    do: node_path(session, "supervision-tree")

  defp settings_return_to_fallback(_active_nav, session), do: node_path(session)

  attr :session, Session, required: true

  defp node_indicator(assigns) do
    assigns = assign(assigns, :long_node_name?, String.length(assigns.session.node_name) > 24)

    ~H"""
    <div
      id="node-status"
      class="border-base-300 flex w-fit min-w-0 max-w-full items-center gap-1.5 rounded-lg border py-1 pr-1 pl-2.5"
    >
      <span class="relative flex h-1.5 w-1.5 shrink-0">
        <span class="bg-success absolute inline-flex h-full w-full animate-ping rounded-full opacity-75">
        </span>
        <span class="bg-success relative inline-flex h-1.5 w-1.5 rounded-full"></span>
      </span>
      <span
        :if={!@long_node_name?}
        class="text-base-content/70 shrink-0 text-xs @max-[20rem]/nav-status:hidden"
      >
        Connected
      </span>
      <span
        class={["font-mono text-base-content/80 min-w-0 truncate text-xs"]}
        title={@session.node_name}
      >
        {@session.node_name}
      </span>
      <.tooltip id="disconnect-tip" position="bottom">
        <button
          id="disconnect"
          type="button"
          title="Disconnect"
          aria-label="Disconnect"
          phx-click="disconnect"
          class="btn btn-ghost btn-square toolbar-btn-sm text-error/80 hover:text-error"
        >
          <.icon name="icon-power" class="toolbar-icon-sm" />
        </button>
        <:content>Disconnect</:content>
      </.tooltip>
    </div>
    """
  end
end

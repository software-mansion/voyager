defmodule VoyagerWeb.Components.Shell do
  @moduledoc """
  App shell components - topbar, sidebar, content area, and status bar.
  """

  use VoyagerWeb, :html

  alias Voyager.NodeSession.Session
  alias Voyager.Services.Tracer
  alias VoyagerWeb.Components.TracingComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.Hooks.UrlHook

  attr :active_nav, :atom, default: nil
  attr :session, Session, required: true
  attr :mcp_status, :map, default: %{alive?: false, url: nil}
  attr :tracing_session, Tracer.Session, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="bg-base-200 flex h-full flex-col overflow-x-auto overflow-y-hidden">
      <div class="min-w-lg flex min-h-0 flex-1 flex-col">
        <.topbar session={@session} mcp_status={@mcp_status} tracing_session={@tracing_session} />

        <div class="relative flex flex-1 overflow-y-hidden">
          <.sidebar
            active_nav={@active_nav}
            session={@session}
            mcp_status={@mcp_status}
          />

          <main class="min-w-lg relative flex-1 overflow-y-auto">
            {render_slot(@inner_block)}
          </main>
        </div>
      </div>
    </div>
    """
  end

  attr :session, Session, required: true
  attr :mcp_status, :map, default: %{alive?: false, url: nil}
  attr :tracing_session, Tracer.Session, default: nil

  defp topbar(assigns) do
    ~H"""
    <div class="bg-base-100 border-base-300 min-h-14 grid-cols-[auto_1fr_auto] z-10 grid flex-none items-center gap-4 border-b px-4">
      <.brand />
      <div class="@container/nav-status flex min-w-0 items-center gap-3">
        <.node_indicator session={@session} />
        <.tracing_indicator session={@tracing_session} connected_node={@session.node} />
      </div>
      <.link
        href={~p"/settings"}
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
  Renders the topbar used by the settings page, showing the brand mark.
  """
  attr :tracing_session, Tracer.Session, default: nil

  def settings_topbar(assigns) do
    ~H"""
    <div class="navbar bg-base-100 border-base-300 min-h-14 z-10 flex-none gap-3 border-b px-4">
      <div class="navbar-start gap-3">
        <.brand />
      </div>
      <div class="navbar-end @container/nav-status min-w-0">
        <.tracing_indicator session={@tracing_session} />
      </div>
    </div>
    """
  end

  attr :session, Tracer.Session, default: nil
  attr :connected_node, :atom, default: nil

  defp tracing_indicator(%{session: nil} = assigns), do: ~H""

  defp tracing_indicator(assigns) do
    assigns =
      assign(assigns,
        tone: TracingComponents.tone(assigns.session, assigns.connected_node),
        state: TracingComponents.state(assigns.session)
      )

    ~H"""
    <.tooltip id="tracing-indicator-tip" position="bottom" class="shrink-0">
      <.link
        navigate={tracing_session_path(@session)}
        id="tracing-indicator"
        data-tone={@tone}
        aria-label={"Open the #{@state} tracing session, #{Formatters.format_integer(@session.traces)} traces captured"}
        class={[
          "flex items-center gap-2 rounded-lg border py-1 pr-1 pl-2.5 transition-colors focus-visible:outline-2 focus-visible:outline-offset-2",
          TracingComponents.tone_class(@tone, :chip)
        ]}
      >
        <span class="relative flex h-1.5 w-1.5 shrink-0">
          <span
            :if={@tone == :running}
            class="bg-success absolute inline-flex h-full w-full animate-ping rounded-full opacity-75"
          ></span>
          <span class={[
            "relative inline-flex h-1.5 w-1.5 rounded-full",
            TracingComponents.tone_class(@tone, :dot)
          ]}></span>
        </span>
        <span
          id="tracing-indicator-label"
          class={[
            "text-xs font-medium @max-sm/nav-status:hidden",
            TracingComponents.tone_class(@tone, :label)
          ]}
        >
          {tracing_label(@session)}
        </span>
        <span
          id="tracing-indicator-mfa"
          class="font-mono text-base-content/70 max-w-56 truncate px-1 text-xs @max-lg/nav-status:hidden"
        >
          {TracingComponents.traced_mfa(@session.config)}
        </span>
        <span
          id="tracing-indicator-count"
          class={[
            "badge badge-sm font-mono h-(--toolbar-btn-size-sm) shrink-0",
            TracingComponents.tone_class(@tone, :badge)
          ]}
        >
          {Formatters.format_count_short(@session.traces)}
        </span>
      </.link>
      <:content>
        <div class="flex flex-col gap-1.5">
          <span class="font-medium">Tracing session {@state}</span>
          <dl class="grid-cols-[auto_1fr] grid gap-x-3 gap-y-0.5">
            <dt class="text-base-content/60">Node</dt>
            <dd id="tracing-indicator-node" class="font-mono">{@session.node}</dd>
            <dd
              :if={@tone == :other_node}
              id="tracing-indicator-other-node"
              role="note"
              class="alert alert-info col-span-2 my-1 gap-1.5 px-2 py-1.5 text-xs"
            >
              <.icon name="icon-info" class="text-info size-3.5 shrink-0" />
              <span>Session associated with a different node.</span>
            </dd>
            <dt class="text-base-content/60">Function</dt>
            <dd class="font-mono">{TracingComponents.traced_mfa(@session.config)}</dd>
            <dt class="text-base-content/60">Traces</dt>
            <dd class="font-mono">{Formatters.format_integer(@session.traces)}</dd>
            <dt :if={@session.stop_reason} class="text-base-content/60">Reason</dt>
            <dd
              :if={@session.stop_reason}
              id="tracing-indicator-reason"
              class={if @tone == :failed, do: "text-warning", else: nil}
            >
              {TracingComponents.stop_reason_label(@session.stop_reason)}
            </dd>
          </dl>
          <span class="border-base-300 text-base-content/70 border-t pt-1.5">
            Click to open the session.
          </span>
        </div>
      </:content>
    </.tooltip>
    """
  end

  defp tracing_session_path(%Tracer.Session{node: node, id: id}),
    do: ~p"/node/#{node}/tracing/#{id}"

  defp tracing_label(%Tracer.Session{status: :running}), do: "Tracing"
  defp tracing_label(%Tracer.Session{status: :stopped}), do: "Stopped"
  defp tracing_label(%Tracer.Session{status: :idle}), do: "Ready"

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

  @feedback_url "https://github.com/software-mansion/voyager/issues/new/choose"

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
            ></span>
            <span class={[
              "relative inline-flex h-1.5 w-1.5 rounded-full",
              if(@status.alive?, do: "bg-success", else: "bg-error")
            ]}></span>
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
            href={~p"/settings"}
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

  defp sidebar(assigns) do
    ~H"""
    <aside
      id="app-sidebar"
      class="bg-base-100 border-base-300 flex h-full flex-none flex-col overflow-y-auto overflow-x-hidden border-r transition-all duration-200 ease-out"
    >
      <ul class="menu font-sans gap-1.75 w-full flex-1">
        <.sidebar_toggle />
        <.nav_item
          :for={page <- inspect_pages()}
          id={"sidebar-nav-#{page.feature}"}
          active={@active_nav == page.feature}
          navigate={UrlHook.without_back_arrow(node_path(@session, page.path))}
          label={page.label}
        >
          <:icon>
            <.icon name={page.icon} class={["toolbar-icon", page[:icon_class]]} />
          </:icon>
        </.nav_item>

        <div class="border-base-content/10 my-4 border-t"></div>
        <span class="menu-title text-base-content/70 tracking-label mb-3 p-0 text-xs uppercase">
          Coming Soon
        </span>

        <.nav_item
          :for={page <- coming_soon_pages()}
          id={"sidebar-nav-#{page.feature}"}
          active={@active_nav == page.feature}
          navigate={UrlHook.without_back_arrow(node_path(@session, page.path))}
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
        <.mcp_status_indicator status={@mcp_status} />
      </div>
    </aside>
    """
  end

  defp sidebar_toggle(assigns) do
    ~H"""
    <li class="sidebar-toggle-row mb-3 flex flex-row items-center justify-between">
      <span class="menu-title text-base-content/70 sidebar-label tracking-label p-0 text-xs uppercase">
        Inspect
      </span>
      <button
        type="button"
        id="sidebar-compact-toggle"
        phx-click={JS.dispatch("phx:toggle-sidebar")}
        aria-label="Toggle sidebar width"
        class="btn btn-ghost btn-square toolbar-btn text-base-content/70 hover:text-base-content"
        phx-hook="Tooltip"
        data-tooltip-target="#sidebar-compact-toggle-tip"
        data-tooltip-position="right"
        data-tooltip-interactive="false"
      >
        <.icon name="icon-panel-left" class="toolbar-icon" />
      </button>
    </li>
    <.tooltip_portal id="sidebar-compact-toggle">
      <span class="flex items-center gap-3 whitespace-nowrap">
        Toggle sidebar
        <span class="flex items-center gap-1">
          <kbd class={["hidden mac:inline-flex", keycap_class()]}>⌘</kbd>
          <kbd class={["inline-flex mac:hidden", keycap_class()]}>Ctrl</kbd>
          <kbd class={["inline-flex", keycap_class()]}>B</kbd>
        </span>
      </span>
    </.tooltip_portal>
    """
  end

  defp keycap_class,
    do:
      "bg-base-content/10 text-base-content/70 h-5 min-w-5 items-center justify-center rounded-sm px-1 font-sans text-xs"

  @inspect_pages [
    %{feature: :node_info, path: nil, label: "Node Info", icon: "icon-grid"},
    %{
      feature: :supervision_tree,
      path: "supervision-tree",
      label: "Supervision Tree",
      icon: "icon-network",
      icon_class: "-rotate-90"
    },
    %{feature: :processes, path: "processes", label: "Processes", icon: "icon-cpu"},
    %{
      feature: :ets_tables,
      path: "ets-tables",
      label: "ETS Tables",
      icon: "icon-database-search"
    }
  ]

  @coming_soon_pages [
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

  attr :id, :string, required: true
  attr :active, :boolean, default: false
  attr :navigate, :any, required: true
  attr :label, :string, required: true
  attr :coming_soon, :boolean, default: false
  slot :icon, required: true

  defp nav_item(assigns) do
    ~H"""
    <li>
      <.link
        id={@id}
        navigate={@navigate}
        class={["sidebar-nav-row", @active && "menu-active"]}
        phx-hook="Tooltip"
        data-tooltip-target={"##{@id}-tip"}
        data-tooltip-position="right"
        data-tooltip-interactive="false"
        data-tooltip-show-when="sidebar-compact"
      >
        {render_slot(@icon)}
        <span class="sidebar-label flex-1 truncate">{@label}</span>
        <span :if={@coming_soon} class="sidebar-badge badge badge-primary badge-soft badge-xs">
          Soon
        </span>
      </.link>
    </li>
    <.tooltip_portal id={@id}>{@label}</.tooltip_portal>
    """
  end

  defp node_path(%Session{node_name: node_name}, nil), do: ~p"/node/#{node_name}"

  defp node_path(%Session{node_name: node_name}, path),
    do: "/node/#{URI.encode(node_name)}/#{path}"

  attr :session, Session, required: true

  defp node_indicator(assigns) do
    assigns = assign(assigns, :long_node_name?, String.length(assigns.session.node_name) > 24)

    ~H"""
    <div
      id="node-status"
      class="border-base-300 flex w-fit min-w-0 max-w-full items-center gap-1.5 rounded-lg border py-1 pr-1 pl-2.5"
    >
      <span class="relative flex h-1.5 w-1.5 shrink-0">
        <span class="bg-success absolute inline-flex h-full w-full animate-ping rounded-full opacity-75"></span>
        <span class="bg-success relative inline-flex h-1.5 w-1.5 rounded-full"></span>
      </span>
      <span
        :if={!@long_node_name?}
        id="node-status-label"
        class="text-base-content/70 shrink-0 text-xs @max-[20rem]/nav-status:hidden"
      >
        {connected_label(@session.connector.name())}
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

  defp connected_label(:ssh), do: "Connected via SSH"
  defp connected_label(_connector), do: "Connected directly"
end

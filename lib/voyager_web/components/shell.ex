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
    <div class="grid grid-rows-[var(--topbar-h)_1fr_var(--statusbar-h)] h-screen">
      <.topbar active_nav={@active_nav} />
      <div class="grid grid-cols-[var(--sidebar-w)_1fr] overflow-hidden">
        <.sidebar active_nav={@active_nav} node={@node} />
        <main class="flex flex-col overflow-hidden relative">
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
    <header class="flex items-center px-5 border-b border-default-border bg-white/75 backdrop-blur-[14px] gap-6 z-10">
      <.brand />
      <div class="flex-1"></div>
      <.link
        navigate={~p"/settings"}
        class={[
          "flex items-center justify-center w-8 h-8 border rounded-md cursor-pointer transition-all duration-150 ease-in-out no-underline",
          "border-default-border text-secondary-text hover:border-strong-border hover:text-primary-text hover:bg-raised-bg",
          @active_nav == :settings && "border-accent-soft text-accent bg-raised-bg"
        ]}
        title="Settings"
      >
        <.icon name="icon-settings" class="size-3.5" />
      </.link>
    </header>
    """
  end

  defp brand(assigns) do
    ~H"""
    <div class="flex items-center gap-2.5 font-semibold tracking-[-0.01em]">
      <div class="relative w-[22px] h-[22px] bg-gradient-to-br from-accent to-accent-soft rounded-[5px] shadow-accent-glow shrink-0">
        <div class="absolute inset-1 bg-white rounded-[2px] shadow-[inset_0_0_0_1.5px_var(--accent)]">
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
    <aside class="border-r border-default-border bg-raised-bg/60 py-4 px-3 overflow-y-auto overflow-x-hidden">
      <div class="mb-6">
        <div class="font-mono text-[10px] tracking-[0.12em] uppercase text-faint-text px-[10px] pb-2">
          Inspect
        </div>
        <.nav_item active={@active_nav == :node_info} navigate={node_path(@node)}>
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
    <span class={[
      "relative flex items-center gap-2.5 py-2 px-[10px] rounded-md text-secondary-text text-[13px] no-underline cursor-default opacity-45"
    ]}>
      <span class="w-4 text-muted-text flex shrink-0">{render_slot(@icon)}</span>
      <span class="flex-1 min-w-0 overflow-hidden text-ellipsis">{render_slot(@inner_block)}</span>
    </span>
    """
  end

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "relative flex items-center gap-2.5 py-2 px-[10px] rounded-md text-secondary-text text-[13px] no-underline cursor-pointer transition-all duration-[120ms] ease-in-out",
        "hover:bg-raised-bg hover:text-primary-text",
        @active &&
          "bg-raised-bg text-primary-text font-medium before:content-[''] before:absolute before:left-0 before:top-2 before:bottom-2 before:w-0.5 before:bg-accent before:rounded-[2px]"
      ]}
    >
      <span class={["w-4 flex shrink-0", (@active && "text-accent") || "text-muted-text"]}>
        {render_slot(@icon)}
      </span>
      <span class="flex-1 min-w-0 overflow-hidden text-ellipsis">{render_slot(@inner_block)}</span>
    </.link>
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
    <footer class="flex items-center border-t border-default-border bg-surface-bg px-4 font-mono text-[10.5px] text-muted-text tracking-[0.04em] gap-[18px]">
      <div class="flex items-center gap-1.5">
        <span class={["w-1.5 h-1.5 rounded-full", status_dot_class(@node)]}></span>
        {node_display(@node)}
      </div>
      <div class="flex-1"></div>
      <div>v0.1.0</div>
    </footer>
    """
  end

  defp status_dot_class(nil), do: "bg-faint-text"
  defp status_dot_class(%Voyager.Node{status: :connected}), do: "bg-good"
  defp status_dot_class(%Voyager.Node{status: :error}), do: "bg-bad"
  defp status_dot_class(_), do: "bg-warn"

  defp node_display(nil), do: "Not connected"
  defp node_display(%Voyager.Node{name: name}), do: to_string(name)
end

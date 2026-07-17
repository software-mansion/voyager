defmodule VoyagerWeb.ComingSoon.MemoryAllocatorsLive do
  use VoyagerWeb, :live_view

  alias VoyagerWeb.Components.ComingSoon

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:active_nav, :memory_allocators)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ComingSoon.panel
      title="Memory Allocators"
      description="Dig into per-allocator memory statistics."
      icon="icon-memory-stick"
    />
    """
  end
end

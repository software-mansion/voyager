defmodule VoyagerWeb.ComingSoon.PortsLive do
  use VoyagerWeb, :live_view

  alias VoyagerWeb.Components.ComingSoon

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:active_nav, :ports)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ComingSoon.panel
      title="Ports"
      description="Inspect open ports and the drivers behind them."
      icon="icon-chevron-right"
    />
    """
  end
end

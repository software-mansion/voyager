defmodule VoyagerWeb.ComingSoon.ChartsLive do
  use VoyagerWeb, :live_view

  alias VoyagerWeb.Components.ComingSoon

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:active_nav, :charts)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ComingSoon.panel
      title="Charts"
      description="Visualize metrics over time with live charts."
      icon="icon-chart-column"
    />
    """
  end
end

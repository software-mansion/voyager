defmodule VoyagerWeb.ComingSoon.TracingLive do
  use VoyagerWeb, :live_view

  alias VoyagerWeb.Components.ComingSoon

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:active_nav, :tracing)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ComingSoon.panel
      title="Tracing"
      description="Trace function calls and messages on the node in real time."
      icon="icon-binoculars"
    />
    """
  end
end

defmodule VoyagerWeb.ComingSoon.SocketsLive do
  use VoyagerWeb, :live_view

  alias VoyagerWeb.Components.ComingSoon

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:active_nav, :sockets)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ComingSoon.panel
      title="Sockets"
      description="Inspect open sockets and their details."
      icon="icon-plug"
    />
    """
  end
end

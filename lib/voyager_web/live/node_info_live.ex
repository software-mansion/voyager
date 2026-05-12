defmodule VoyagerWeb.NodeInfoLive do
  use VoyagerWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :active_nav, :node_info)}
  end

  def render(assigns) do
    ~H"""
    <p>Node Info</p>
    """
  end
end

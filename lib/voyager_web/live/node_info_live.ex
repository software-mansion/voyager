defmodule VoyagerWeb.NodeInfoLive do
  use VoyagerWeb, :live_view

  def mount(%{"node" => node}, _session, socket) do
    {:ok, assign(socket, active_nav: :node_info, node: node)}
  end

  def render(assigns) do
    ~H"""
    <p>Node Info</p>
    """
  end
end

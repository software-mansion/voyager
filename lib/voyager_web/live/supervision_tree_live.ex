defmodule VoyagerWeb.SupervisionTreeLive do
  use VoyagerWeb, :live_view

  def mount(%{"node" => node}, _session, socket) do
    {:ok, assign(socket, active_nav: :supervision_tree, node: node)}
  end

  def render(assigns) do
    ~H"""
    <p>Supervision Tree</p>
    """
  end
end

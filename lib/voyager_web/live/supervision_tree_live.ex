defmodule VoyagerWeb.SupervisionTreeLive do
  use VoyagerWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :active_nav, :supervision_tree)}
  end

  def render(assigns) do
    ~H"""
    <p>Supervision Tree</p>
    """
  end
end

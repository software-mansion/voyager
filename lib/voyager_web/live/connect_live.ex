defmodule VoyagerWeb.ConnectLive do
  use VoyagerWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <p>Connect</p>
    """
  end
end

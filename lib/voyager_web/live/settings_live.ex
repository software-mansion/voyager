defmodule VoyagerWeb.SettingsLive do
  use VoyagerWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, active_nav: :settings, node: nil)}
  end

  def render(assigns) do
    ~H"""
    <p>Settings</p>
    """
  end
end

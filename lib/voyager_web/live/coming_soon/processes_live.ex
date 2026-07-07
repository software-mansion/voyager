defmodule VoyagerWeb.ComingSoon.ProcessesLive do
  use VoyagerWeb, :live_view

  alias VoyagerWeb.Components.ComingSoon

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:active_nav, :processes)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ComingSoon.panel
      title="Processes"
      description="Browse and inspect every process running on the connected node."
      icon="icon-cpu"
    />
    """
  end
end

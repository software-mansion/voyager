defmodule VoyagerWeb.ComingSoon.EtsTablesLive do
  use VoyagerWeb, :live_view

  alias VoyagerWeb.Components.ComingSoon

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:active_nav, :ets_tables)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ComingSoon.panel
      title="ETS Tables"
      description="Explore ETS tables, their contents, and memory footprint."
      icon="icon-diamond"
    />
    """
  end
end

defmodule VoyagerWeb.SupervisionTreeLive do
  use VoyagerWeb, :live_view

  def mount(%{"node" => node}, _session, socket) do
    {:ok, assign(socket, active_nav: :supervision_tree, node: node)}
  end

  def render(assigns) do
    ~H"""
    <Shell.shell active_nav={@active_nav} node={@node}>
      <p>Supervision Tree</p>
    </Shell.shell>
    """
  end
end

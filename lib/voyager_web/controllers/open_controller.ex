defmodule VoyagerWeb.OpenController do
  use VoyagerWeb, :controller

  alias Voyager.NodeSession

  def show(conn, _params) do
    path =
      case NodeSession.current() do
        nil -> ~p"/"
        session -> ~p"/node/#{session.node_name}"
      end

    redirect(conn, to: path)
  end
end

defmodule VoyagerWeb.OpenControllerTest do
  # async: false because the node session is a global GenServer.
  use VoyagerWeb.ConnCase, async: false

  alias Voyager.Fakes

  @node_name "shop@10.0.4.12"

  test "opens the connect page without a node", %{conn: conn} do
    Fakes.connect_node!(nil)

    assert redirected_to(get(conn, ~p"/open")) == ~p"/"
  end

  test "opens the connected node", %{conn: conn} do
    Fakes.connect_node!(Fakes.node_session(node_name: @node_name))

    assert redirected_to(get(conn, ~p"/open")) == ~p"/node/#{@node_name}"
  end
end

defmodule Voyager.MCP.Tools.Disconnect do
  @moduledoc """
  Disconnects Voyager from the node it is connected to, ending the session the
  user may be looking at in the Voyager window. Use it to switch nodes before
  `connect`.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.NodeSession

  schema do
  end

  @impl true
  def execute(_params, frame) do
    response =
      case NodeSession.current() do
        nil ->
          Response.error(Response.tool(), "Not connected to any node")

        session ->
          NodeSession.disconnect()
          Response.json(Response.tool(), %{status: "disconnected", node: session.node_name})
      end

    {:reply, response, frame}
  end
end

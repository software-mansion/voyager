defmodule Voyager.MCP.Tools.ConnectionStatus do
  @moduledoc """
  MCP tool reporting whether Voyager is connected to a remote node, and which one.

  Cheap orientation call: agents use it before `node_info` to confirm a live
  connection exists.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.NodeSession

  schema do
  end

  @impl true
  def execute(_params, frame) do
    payload =
      case NodeSession.current() do
        nil ->
          %{connected: false}

        session ->
          %{
            connected: true,
            node: to_string(session.node),
            node_name: session.node_name,
            connected_at: session.connected_at
          }
      end

    {:reply, Response.json(Response.tool(), payload), frame}
  end
end

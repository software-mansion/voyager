defmodule Voyager.MCP.Tools.NodeInfo do
  @moduledoc """
  MCP tool returning a point-in-time introspection snapshot of the connected node.

  Delegates to `Voyager.Services.NodeInfo.fetch/2` against the node held by
  `Voyager.NodeSession`, returning system / memory / runtime / limits / schedulers
  / run-queue data as JSON.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.NodeSession
  alias Voyager.Services.NodeInfo

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case NodeSession.current() do
      nil ->
        {:reply, Response.error(Response.tool(), "Not connected to any node"), frame}

      session ->
        case NodeInfo.fetch(session.node) do
          {:ok, snapshot} ->
            {:reply, Response.json(Response.tool(), snapshot), frame}

          {:error, reason} ->
            {:reply, Response.error(Response.tool(), "fetch failed: #{inspect(reason)}"), frame}
        end
    end
  end
end

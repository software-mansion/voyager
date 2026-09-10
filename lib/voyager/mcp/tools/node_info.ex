defmodule Voyager.MCP.Tools.NodeInfo do
  @moduledoc """
  MCP tool returning a point-in-time introspection snapshot of the connected node.

  Delegates to `Voyager.Services.NodeInfo.fetch/2` against the node held by
  `Voyager.NodeSession`, returning system / memory / runtime / limits / schedulers
  / run-queue data as JSON.
  """

  use Anubis.Server.Component, type: :tool

  alias Voyager.MCP.Tools.Remote
  alias Voyager.Services.NodeInfo

  schema do
  end

  @impl true
  def execute(_params, frame) do
    Remote.reply(&NodeInfo.fetch(&1), frame)
  end
end

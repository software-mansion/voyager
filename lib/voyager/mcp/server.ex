defmodule Voyager.MCP.Server do
  @moduledoc """
  MCP server exposing BEAM node introspection to coding agents.
  """

  use Anubis.Server,
    name: "Voyager",
    version: Voyager.version(),
    capabilities: [:tools]

  component(Voyager.MCP.Tools.NodeInfo)

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end

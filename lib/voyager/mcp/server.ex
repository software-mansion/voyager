defmodule Voyager.MCP.Server do
  @moduledoc """
  MCP server exposing BEAM node introspection to coding agents.
  """

  use Anubis.Server,
    name: "Voyager",
    version: Voyager.version(),
    capabilities: [:tools]

  component(Voyager.MCP.Tools.NodeInfo)
  component(Voyager.MCP.Tools.ProcessList)
  component(Voyager.MCP.Tools.ProcessInfo)

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end

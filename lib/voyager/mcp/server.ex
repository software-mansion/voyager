defmodule Voyager.MCP.Server do
  @moduledoc """
  MCP server exposing read-only BEAM node introspection to coding agents.

  Runs in-app and reuses the live connection held by `Voyager.NodeSession`, so
  tools inspect whichever node the user connected through the Voyager UI. Mounted
  over Streamable HTTP at `/mcp` (see `VoyagerWeb.Router`).
  """

  use Anubis.Server,
    name: "Voyager",
    version: "0.1.0",
    capabilities: [:tools]

  component Voyager.MCP.Tools.ConnectionStatus
  component Voyager.MCP.Tools.NodeInfo

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end

defmodule VoyagerWeb.Hooks.McpAgentsHook do
  @moduledoc """
  Keeps `@mcp_agents` in sync with `Voyager.Services.McpAgents` for the sidebar AI agents
  indicator and the MCP settings card.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Voyager.Services.McpAgents

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, McpAgents.topic())
    end

    socket =
      socket
      |> assign(:mcp_agents, McpAgents.get())
      |> attach_hook(:mcp_agents, :handle_info, &handle_mcp_agents/2)

    {:cont, socket}
  end

  defp handle_mcp_agents({:mcp_agents, agents}, socket) do
    {:halt, assign(socket, :mcp_agents, agents)}
  end

  defp handle_mcp_agents(_message, socket), do: {:cont, socket}
end

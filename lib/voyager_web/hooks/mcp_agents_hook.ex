defmodule VoyagerWeb.Hooks.McpAgentsHook do
  @moduledoc """
  Keeps `@mcp_agents` in sync with `Voyager.Services.McpAgents` and handles the
  sidebar popover's `"mcp-turn-on"` and `"mcp-refresh"` events.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Voyager.MCP
  alias Voyager.Services.McpAgents

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, McpAgents.topic())
    end

    socket =
      socket
      |> assign(:mcp_agents, McpAgents.get())
      |> attach_hook(:mcp_agents, :handle_info, &handle_mcp_info/2)
      |> attach_hook(:mcp_agents, :handle_event, &handle_mcp_event/3)

    {:cont, socket}
  end

  defp handle_mcp_info({:mcp_agents, agents}, socket) do
    {:halt, assign(socket, :mcp_agents, agents)}
  end

  defp handle_mcp_info(_message, socket), do: {:cont, socket}

  defp handle_mcp_event("mcp-turn-on", _params, socket) do
    # The click may come from a popover rendered before the server came up.
    result = if MCP.info().alive?, do: {:ok, :running}, else: MCP.toggle()

    case result do
      {:ok, _state} -> {:halt, socket}
      {:error, reason} -> {:halt, put_flash(socket, :error, turn_on_error(reason))}
    end
  end

  defp handle_mcp_event("mcp-refresh", _params, socket) do
    McpAgents.refresh()
    {:halt, socket}
  end

  defp handle_mcp_event(_event, _params, socket), do: {:cont, socket}

  defp turn_on_error(:port_in_use), do: "MCP port is already in use"
  defp turn_on_error(:locked), do: "MCP server is controlled by application config"
  defp turn_on_error(reason), do: "Failed to turn on the MCP server: #{inspect(reason)}"
end

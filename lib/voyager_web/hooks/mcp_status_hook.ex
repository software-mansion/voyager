defmodule VoyagerWeb.Hooks.McpStatusHook do
  @moduledoc """
  LiveView hook that keeps `@mcp_status` in sync with the MCP endpoint via
  PubSub, for the navbar status indicator.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Voyager.MCP

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, MCP.topic())
    end

    socket =
      socket
      |> assign(:mcp_status, MCP.info())
      |> attach_hook(:mcp_status, :handle_info, &handle_mcp_status/2)

    {:cont, socket}
  end

  defp handle_mcp_status({:mcp_status, status}, socket) do
    {:halt, assign(socket, :mcp_status, status)}
  end

  defp handle_mcp_status(_event, socket), do: {:cont, socket}
end

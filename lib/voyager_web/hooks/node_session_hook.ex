defmodule VoyagerWeb.Hooks.NodeSessionHook do
  @moduledoc """
  LiveView hook to ensure an active connection to a specific remote node.
  Handles redirects on disconnects and updates session state via PubSub.
  """

  use VoyagerWeb, :verified_routes
  import Phoenix.LiveView
  import Phoenix.Component

  alias Voyager.NodeSession

  def on_mount(:require_connected_node, %{"node" => node_name}, _session, socket) do
    session = NodeSession.current()

    if is_nil(session) or session.node_name != node_name do
      {:halt, push_navigate(socket, to: ~p"/")}
    else
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())
      end

      socket =
        socket
        |> assign(:node, build_node(session))
        |> assign(:session, session)
        |> attach_hook(:nodedown_redirect, :handle_info, &handle_nodedown/2)
        |> attach_hook(:session_info_update, :handle_info, &handle_info_update/2)
        |> attach_hook(:disconnect, :handle_event, &handle_disconnect/3)

      {:cont, socket}
    end
  end

  defp handle_nodedown(
         {:nodedown, event_node},
         %{assigns: %{session: %{node: event_node}}} = socket
       ) do
    {:halt, push_navigate(socket, to: ~p"/")}
  end

  defp handle_nodedown(_event, socket), do: {:cont, socket}

  defp handle_info_update(
         {:node_info_updated, event_node, _info},
         %{assigns: %{session: %{node: event_node}}} = socket
       ) do
    {:cont, assign(socket, :session, NodeSession.current())}
  end

  defp handle_info_update(_event, socket), do: {:cont, socket}

  defp handle_disconnect("disconnect", _params, socket) do
    Voyager.NodeSession.disconnect()
    {:halt, push_navigate(socket, to: ~p"/")}
  end

  defp handle_disconnect(_event, _params, socket), do: {:cont, socket}

  defp build_node(session) do
    %Voyager.Node{
      name: session.node,
      status: :connected,
      connected_at: session.connected_at
    }
  end
end

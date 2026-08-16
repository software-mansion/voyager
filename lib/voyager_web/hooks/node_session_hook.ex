defmodule VoyagerWeb.Hooks.NodeSessionHook do
  @moduledoc """
  LiveView hooks for node session lifecycle.

  * `:require_connected_node` — for node-scoped pages: require a matching session,
    handle shell disconnect, and redirect with flash on disconnect/nodedown.
  * `:observe_node_session` — for the connect page: handle disconnect and show the
    same flash on disconnect/nodedown without redirecting (LiveView updates UI).
  """

  use VoyagerWeb, :verified_routes
  import Phoenix.LiveView
  import Phoenix.Component
  import VoyagerWeb.Helpers

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
        |> assign(:session, session)
        |> attach_hook(:no_node_redirect, :handle_info, &handle_no_node/2)
        |> attach_hook(:disconnect, :handle_event, &handle_disconnect/3)

      {:cont, socket}
    end
  end

  def on_mount(:observe_node_session, _params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())
    end

    socket =
      socket
      |> attach_hook(:session_lost_flash, :handle_info, &handle_session_lost_flash/2)
      |> attach_hook(:disconnect, :handle_event, &handle_disconnect/3)

    {:cont, socket}
  end

  defp handle_no_node(
         {:node_disconnected, event_node} = event,
         %{assigns: %{session: %{node: event_node}}} = socket
       ) do
    socket
    |> put_disconnect_flash(event)
    |> redirect(to: ~p"/")
    |> halt()
  end

  defp handle_no_node(
         {:nodedown, event_node, _reason} = event,
         %{assigns: %{session: %{node: event_node}}} = socket
       ) do
    socket
    |> put_disconnect_flash(event)
    |> redirect(to: ~p"/")
    |> halt()
  end

  defp handle_no_node(_event, socket), do: {:cont, socket}

  defp handle_session_lost_flash({:node_disconnected, _node} = event, socket) do
    {:cont, put_disconnect_flash(socket, event)}
  end

  defp handle_session_lost_flash({:nodedown, _node, _reason} = event, socket) do
    {:cont, put_disconnect_flash(socket, event)}
  end

  defp handle_session_lost_flash(_event, socket), do: {:cont, socket}

  defp handle_disconnect("disconnect", _params, socket) do
    NodeSession.disconnect()
    {:halt, socket}
  end

  defp handle_disconnect(_event, _params, socket), do: {:cont, socket}

  # Puts the shared disconnect / nodedown flash used across node and connect views.
  defp put_disconnect_flash(socket, {:node_disconnected, node}) do
    put_flash(socket, :info, "Node disconnected: #{node}")
  end

  defp put_disconnect_flash(socket, {:nodedown, node, reason}) do
    put_flash(socket, :error, "Node down: #{node}#{nodedown_reason_suffix(reason)}")
  end

  defp nodedown_reason_suffix(:net_tick_timeout),
    do: " — connection timed out, check your network"

  defp nodedown_reason_suffix(:connection_closed), do: " — connection closed"
  defp nodedown_reason_suffix(:no_network), do: " — no network available"
  defp nodedown_reason_suffix(:connection_setup_failed), do: " — connection setup failed"
  defp nodedown_reason_suffix(:disconnect), do: " — disconnected"
  defp nodedown_reason_suffix(:transport_down), do: " — connection lost"
  defp nodedown_reason_suffix(_reason), do: ""
end

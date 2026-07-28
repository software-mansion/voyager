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
        |> attach_hook(:track_current_path, :handle_params, &track_current_path/3)

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

  defp track_current_path(_params, uri, socket) do
    {:cont, assign(socket, :current_path, current_path(uri))}
  end

  defp current_path(uri) when is_binary(uri) do
    %URI{path: path, query: query} = URI.parse(uri)
    path = path || "/"

    if query, do: path <> "?" <> query, else: path
  end

  defp current_path(_), do: "/"

  defp handle_no_node(
         {event, event_node},
         %{assigns: %{session: %{node: event_node}}} = socket
       )
       when event in [:node_disconnected, :nodedown] do
    socket
    |> put_disconnect_flash({event, event_node})
    |> redirect(to: ~p"/")
    |> halt()
  end

  defp handle_no_node(_event, socket), do: {:cont, socket}

  defp handle_session_lost_flash({event, node}, socket)
       when event in [:node_disconnected, :nodedown] do
    {:cont, put_disconnect_flash(socket, {event, node})}
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

  defp put_disconnect_flash(socket, {:nodedown, node}) do
    put_flash(socket, :error, "Node down: #{node}")
  end
end

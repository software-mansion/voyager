defmodule Voyager.Services.TrayStatus do
  @moduledoc """
  Bridges the Tauri tray menu over `ElixirKit.PubSub` on the `"tray"` topic.

  Sends `%{node, node_lost, connector, connected_at, mcp_url}` as JSON whenever the
  node session or the MCP listener changes, and runs the `"disconnect"` and
  `"toggle_mcp"` actions.
  """

  use GenServer

  alias Voyager.MCP
  alias Voyager.NodeSession

  @native_topic "tray"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    if Keyword.fetch!(opts, :native?) do
      ElixirKit.PubSub.subscribe(@native_topic)
      Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())
      Phoenix.PubSub.subscribe(Voyager.PubSub, MCP.topic())

      state =
        %{node_lost: false, mcp_url: mcp_url(MCP.info())}
        |> Map.merge(session_fields(NodeSession.current()))

      {:ok, push(state)}
    else
      :ignore
    end
  end

  @impl GenServer
  def handle_info("disconnect", state) do
    NodeSession.disconnect()
    {:noreply, state}
  end

  def handle_info("toggle_mcp", state) do
    MCP.toggle()
    {:noreply, state}
  end

  def handle_info({:node_connected, node}, state) do
    fields = session_fields(NodeSession.current() || %{node: node})
    {:noreply, push(%{Map.merge(state, fields) | node_lost: false})}
  end

  def handle_info({:nodedown, node, _reason}, state) do
    {:noreply, push(%{state | node: node, node_lost: true})}
  end

  def handle_info({:node_disconnected, _node, _reason}, state) do
    state = Map.merge(state, session_fields(nil))
    {:noreply, push(%{state | node_lost: false})}
  end

  def handle_info({:mcp_status, status}, state) do
    {:noreply, push(%{state | mcp_url: mcp_url(status)})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp session_fields(nil), do: %{node: nil, connector: nil, connected_at: nil}

  defp session_fields(%NodeSession.Session{} = session) do
    %{
      node: session.node,
      connector: connector_label(session.connector.name()),
      connected_at: DateTime.to_unix(session.connected_at)
    }
  end

  defp session_fields(%{node: node}), do: %{node: node, connector: nil, connected_at: nil}

  defp connector_label(:ssh), do: "SSH tunnel"
  defp connector_label(_name), do: "Distribution"

  defp mcp_url(%{alive?: true, url: url}), do: url
  defp mcp_url(_status), do: nil

  defp push(state) do
    ElixirKit.PubSub.broadcast(@native_topic, JSON.encode!(state))
    state
  end
end

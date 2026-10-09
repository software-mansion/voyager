defmodule Voyager.Services.TrayStatus do
  @moduledoc """
  Bridges the Tauri tray menu over `ElixirKit.PubSub` on the `"tray"` topic.

  Sends `%{node, node_lost, connector, connected_at, mcp_url, last_connected,
  connecting, error}` as JSON whenever the node session or the MCP listener
  changes, and runs the `"connect"`, `"disconnect"`, `"toggle_mcp"`, `"refresh"`
  and `"dismiss_error"` actions.
  """

  use GenServer

  alias Voyager.Actions.Connections, as: ConnectionActions
  alias Voyager.Actions.SshConnections, as: SshConnectionActions
  alias Voyager.MCP
  alias Voyager.NodeSession
  alias Voyager.NodeSession.Connectors.Ssh, as: SshConnector
  alias Voyager.Queries.Connections, as: ConnectionQueries
  alias Voyager.Queries.SshConnections, as: SshConnectionQueries
  alias Voyager.Schemas.Connection
  alias Voyager.Schemas.SshConnection

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
        %{node_lost: false, mcp_url: mcp_url(MCP.info()), connecting: false, error: nil}
        |> Map.merge(session_fields(NodeSession.current()))

      {:ok, push(state)}
    else
      :ignore
    end
  end

  @impl GenServer
  def handle_info("connect", %{connecting: false, node: nil} = state) do
    case last_connectable() do
      nil ->
        {:noreply, push(state)}

      connection ->
        Task.Supervisor.async_nolink(Voyager.TaskSupervisor, fn -> connect(connection) end)
        {:noreply, push(%{state | connecting: true, error: nil})}
    end
  end

  def handle_info("disconnect", state) do
    NodeSession.disconnect()
    {:noreply, state}
  end

  def handle_info("toggle_mcp", state) do
    error =
      case MCP.toggle() do
        {:ok, _status} -> nil
        {:error, reason} -> mcp_error(reason)
      end

    {:noreply, push(%{state | error: error})}
  end

  def handle_info("refresh", state), do: {:noreply, push(state)}

  def handle_info("dismiss_error", %{error: error} = state) when error != nil do
    {:noreply, push(%{state | error: nil})}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    error = if result != :ok, do: connect_error(result)
    {:noreply, push(%{state | connecting: false, error: error})}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, push(%{state | connecting: false, error: connect_error(:crashed)})}
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

  defp last_connectable do
    [ConnectionQueries.last_connectable(), SshConnectionQueries.last_connectable()]
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(& &1.last_connected_at, DateTime, fn -> nil end)
  end

  defp last_connected_fields(nil), do: nil

  defp last_connected_fields(%Connection{} = connection),
    do: %{node: connection.node_name, connector: connector_label(:distribution)}

  defp last_connected_fields(%SshConnection{} = connection),
    do: %{node: connection.node_name, connector: connector_label(:ssh)}

  defp connect(%Connection{} = c) do
    with :ok <- NodeSession.connect(c.node_name, c.cookie, name_type: c.name_type) do
      ConnectionActions.upsert_connected(c.node_name, name_type: c.name_type)
      :ok
    end
  end

  defp connect(%SshConnection{} = c) do
    auth = if c.auth_method == :password, do: {:password, c.password}, else: :agent

    opts = [
      ssh_user: c.ssh_user,
      ssh_host: c.ssh_host,
      auth: auth,
      ssh_port: c.ssh_port,
      epmd_port: c.epmd_port,
      name_type: c.name_type
    ]

    with :ok <- NodeSession.connect_via(SshConnector, c.node_name, c.cookie, opts) do
      SshConnectionActions.upsert_connected(c.ssh_user, c.ssh_host, c.ssh_port, c.node_name,
        name_type: c.name_type,
        auth_method: c.auth_method,
        epmd_port: c.epmd_port
      )

      :ok
    end
  end

  defp connect_error({:error, reason}) when reason in [:bad_cookie, :node_connect_failed],
    do: "The Erlang cookie does not match"

  defp connect_error({:error, reason}) when is_list(reason), do: "SSH authentication failed"

  defp connect_error({:error, reason})
       when reason in [:node_not_registered, :connection_failed] or
              (is_tuple(reason) and elem(reason, 0) == :node_not_found),
       do: "Node not found, check it is running"

  defp connect_error({:error, {tag, _reason}}) when tag in [:epmd_error, :node_unreachable],
    do: "Node unreachable, check the host and your network"

  defp connect_error({:error, reason})
       when reason in [:etimedout, :econnrefused, :nxdomain, :ehostunreach, :enetunreach],
       do: "SSH host unreachable, check the host and your network"

  defp connect_error(_result), do: "Could not connect to the node"

  defp mcp_error(:port_in_use), do: "MCP port is already in use"
  defp mcp_error(:locked), do: "MCP server is controlled by application config"
  defp mcp_error(reason), do: "Could not toggle the MCP server: #{inspect(reason)}"

  defp push(state) do
    payload = Map.put(state, :last_connected, last_connected_fields(last_connectable()))
    ElixirKit.PubSub.broadcast(@native_topic, JSON.encode!(payload))
    state
  end
end

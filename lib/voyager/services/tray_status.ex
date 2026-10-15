defmodule Voyager.Services.TrayStatus do
  @moduledoc """
  Bridges the Tauri tray menu over `ElixirKit.PubSub` on the `"tray"` topic.

  Sends `%{connection, mcp, last_connection, connecting, error}` as JSON whenever
  the node session or the MCP listener changes; a `nil` `connection` means
  disconnected and a `nil` `mcp` means stopped. Runs the `"connect"`,
  `"disconnect"`, `"mcp_on"`, `"mcp_off"`, `"refresh"` and `"dismiss_error"`
  actions.
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
  @connect_error "Could not connect"

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

      state = %{
        connection: connection_info(NodeSession.current()),
        mcp: mcp_info(MCP.info()),
        last_connection: last_connectable(),
        connecting: false,
        connect_task: nil,
        error: nil
      }

      {:ok, push(state)}
    else
      :ignore
    end
  end

  @impl GenServer
  def handle_info("connect", %{connecting: false, connection: nil, last_connection: last} = state)
      when last != nil do
    task = Task.Supervisor.async_nolink(Voyager.TaskSupervisor, fn -> connect(last) end)
    {:noreply, push(%{state | connecting: true, connect_task: task.ref, error: nil})}
  end

  def handle_info("disconnect", state) do
    NodeSession.disconnect()
    {:noreply, state}
  end

  def handle_info(action, state) when action in ["mcp_on", "mcp_off"] do
    error =
      if MCP.info().alive? != (action == "mcp_on") do
        case MCP.toggle() do
          {:ok, _status} -> nil
          {:error, reason} -> mcp_error(reason)
        end
      end

    {:noreply, push(%{state | error: error})}
  end

  def handle_info("refresh", state), do: {:noreply, push(state)}

  def handle_info("dismiss_error", %{error: error} = state) when error != nil do
    {:noreply, push(%{state | error: nil})}
  end

  # Reply from the async_nolink connect task; :flush drops its trailing :DOWN.
  def handle_info({ref, _result}, %{connect_task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | connect_task: nil}}
  end

  # The connect task crashed, otherwise "Connecting…" would never clear.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{connect_task: ref} = state) do
    {:noreply, push(%{state | connecting: false, connect_task: nil, error: @connect_error})}
  end

  def handle_info({:node_connecting, _node_name}, %{connecting: false} = state) do
    {:noreply, push(%{state | connecting: true, error: nil})}
  end

  def handle_info({:node_connect_failed, _node_name, _reason}, state) do
    {:noreply, push(%{state | connecting: false, error: @connect_error})}
  end

  def handle_info({:node_connected, _node}, state) do
    state = %{state | connection: connection_info(NodeSession.current()), connecting: false}
    {:noreply, push(%{state | last_connection: last_connectable()})}
  end

  def handle_info({event, _node, _reason}, state) when event in [:node_disconnected, :nodedown] do
    {:noreply, push(%{state | connection: nil, last_connection: last_connectable()})}
  end

  def handle_info({:mcp_status, status}, state) do
    {:noreply, push(%{state | mcp: mcp_info(status)})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp connection_info(nil), do: nil

  defp connection_info(%NodeSession.Session{} = session) do
    %{
      node: session.node,
      connector: connector_label(session.connector.name()),
      connected_at: DateTime.to_unix(session.connected_at)
    }
  end

  defp connector_label(:ssh), do: "SSH tunnel"
  defp connector_label(_name), do: "Distribution"

  defp mcp_info(%{alive?: true, url: url}), do: %{url: url}
  defp mcp_info(_status), do: nil

  defp last_connectable do
    [ConnectionQueries.last_connectable(), SshConnectionQueries.last_connectable()]
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(& &1.last_connected_at, DateTime, fn -> nil end)
  end

  defp last_connection_info(nil), do: nil

  defp last_connection_info(%Connection{} = connection),
    do: %{node: connection.node_name, connector: connector_label(:distribution), host: nil}

  defp last_connection_info(%SshConnection{} = connection),
    do: %{node: connection.node_name, connector: connector_label(:ssh), host: connection.ssh_host}

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

  defp mcp_error(:port_in_use), do: "MCP port is already in use"
  defp mcp_error(:locked), do: "MCP server is controlled by application config"
  defp mcp_error(reason), do: "Could not toggle the MCP server: #{inspect(reason)}"

  defp push(state) do
    payload =
      state
      |> Map.delete(:connect_task)
      |> Map.update!(:last_connection, &last_connection_info/1)

    ElixirKit.PubSub.broadcast(@native_topic, JSON.encode!(payload))
    state
  end
end

defmodule Voyager.NodeSession do
  @moduledoc """
  GenServer holding the single active connection to a remote BEAM node.

  Supports two connection modes:
  - `:distribution` — direct Erlang distribution via `NodeConnector`
  - `:ssh` — SSH-tunnelled distribution via `RemoteNodeConnector`
  """

  use GenServer
  alias Voyager.ProxyEpmd.TunnelRegistry
  alias Voyager.Services.NodeConnector
  alias Voyager.Services.RemoteNodeConnector

  defmodule Session do
    @moduledoc "Holds state for an active connection to a remote BEAM node."

    @type t :: %__MODULE__{
            node: atom(),
            node_name: String.t(),
            cookie: String.t(),
            connected_at: DateTime.t(),
            via: :distribution | :ssh,
            conn_ref: :ssh.connection_ref() | nil,
            local_port: pos_integer() | nil,
            ssh_user: String.t() | nil,
            ssh_host: String.t() | nil
          }

    defstruct [
      :node,
      :node_name,
      :cookie,
      :connected_at,
      via: :distribution,
      conn_ref: nil,
      local_port: nil,
      ssh_user: nil,
      ssh_host: nil
    ]
  end

  @pubsub_topic "node_session"

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec connect(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def connect(node_name, cookie, opts \\ []) do
    GenServer.call(__MODULE__, {:connect, node_name, cookie, opts}, 15_000)
  end

  @spec connect_ssh(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def connect_ssh(node_name, cookie, ssh_opts) do
    GenServer.call(__MODULE__, {:connect_ssh, node_name, cookie, ssh_opts}, 30_000)
  end

  @spec disconnect() :: :ok | {:error, :not_connected}
  def disconnect do
    GenServer.call(__MODULE__, :disconnect)
  end

  @spec current() :: Session.t() | nil
  def current do
    GenServer.call(__MODULE__, :current)
  end

  @spec connected?() :: boolean()
  def connected? do
    GenServer.call(__MODULE__, :connected?)
  end

  def topic, do: @pubsub_topic

  @impl GenServer
  def init(_opts) do
    Phoenix.PubSub.subscribe(Voyager.PubSub, TunnelRegistry.topic())
    {:ok, %{session: nil}}
  end

  @impl GenServer
  def handle_call({:connect, _node_name, _cookie, _opts}, _from, %{session: session} = state)
      when not is_nil(session) do
    {:reply, {:error, :already_connected}, state}
  end

  def handle_call({:connect, node_name, cookie, opts}, _from, %{session: nil} = state) do
    name_type = Keyword.get(opts, :name_type, :longnames)

    case NodeConnector.connect(node_name, cookie, name_type: name_type) do
      {:ok, node} ->
        Node.monitor(node, true)

        session = %Session{
          node: node,
          node_name: node_name,
          cookie: cookie,
          connected_at: DateTime.utc_now()
        }

        broadcast({:node_connected, node})
        Voyager.Telemetry.dispatch!("voyager.node.connect")
        {:reply, :ok, %{state | session: session}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(
        {:connect_ssh, _node_name, _cookie, _ssh_opts},
        _from,
        %{session: session} = state
      )
      when not is_nil(session) do
    {:reply, {:error, :already_connected}, state}
  end

  def handle_call({:connect_ssh, node_name, cookie, ssh_opts}, _from, %{session: nil} = state) do
    ssh_user = Keyword.fetch!(ssh_opts, :ssh_user)
    ssh_host = Keyword.fetch!(ssh_opts, :ssh_host)
    auth = Keyword.get(ssh_opts, :auth, :agent)
    rc_opts = Keyword.take(ssh_opts, [:ssh_port, :epmd_port, :name_type])

    case RemoteNodeConnector.connect(ssh_user, ssh_host, node_name, cookie, auth, rc_opts) do
      {:ok, node, conn_ref, local_port} ->
        Node.monitor(node, true)

        session = %Session{
          node: node,
          node_name: node_name,
          cookie: cookie,
          connected_at: DateTime.utc_now(),
          via: :ssh,
          conn_ref: conn_ref,
          local_port: local_port,
          ssh_user: ssh_user,
          ssh_host: ssh_host
        }

        broadcast({:node_connected, node})
        Voyager.Telemetry.dispatch!("voyager.node.connect", metadata: %{via: :ssh})
        {:reply, :ok, %{state | session: session}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:disconnect, _from, %{session: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:disconnect, _from, %{session: %Session{via: :ssh} = session} = state) do
    Node.monitor(session.node, false)
    RemoteNodeConnector.stop(session.conn_ref)
    broadcast({:node_disconnected, session.node})

    Voyager.Telemetry.dispatch!("voyager.node.disconnect",
      metadata: %{reason: "manual disconnect"}
    )

    {:reply, :ok, %{state | session: nil}}
  end

  def handle_call(:disconnect, _from, %{session: session} = state) do
    Node.monitor(session.node, false)
    NodeConnector.disconnect(session.node)
    broadcast({:node_disconnected, session.node})

    Voyager.Telemetry.dispatch!("voyager.node.disconnect",
      metadata: %{reason: "manual disconnect"}
    )

    {:reply, :ok, %{state | session: nil}}
  end

  def handle_call(:current, _from, state) do
    {:reply, state.session, state}
  end

  def handle_call(:connected?, _from, state) do
    {:reply, match?(%Session{}, state.session), state}
  end

  @impl GenServer
  # Tunnel died (TunnelRegistry broadcasts this) — clean up SSH session
  def handle_info(
        {:tunnel_down, conn_ref},
        %{session: %Session{via: :ssh, conn_ref: session_conn_ref} = session} = state
      )
      when conn_ref == session_conn_ref do
    Node.monitor(session.node, false)
    broadcast({:nodedown, session.node})
    Voyager.Telemetry.dispatch!("voyager.node.disconnect", metadata: %{reason: "tunnel down"})
    {:noreply, %{state | session: nil}}
  end

  # Node went down while connected via SSH — also tear down the tunnel
  def handle_info(
        {:nodedown, node},
        %{session: %Session{via: :ssh, node: session_node} = session} = state
      )
      when node == session_node do
    Node.monitor(node, false)
    RemoteNodeConnector.stop(session.conn_ref)
    broadcast({:nodedown, node})
    Voyager.Telemetry.dispatch!("voyager.node.disconnect", metadata: %{reason: "node down"})
    {:noreply, %{state | session: nil}}
  end

  def handle_info({:nodedown, node}, %{session: %Session{node: session_node}} = state)
      when node == session_node do
    Node.monitor(node, false)
    broadcast({:nodedown, node})
    Voyager.Telemetry.dispatch!("voyager.node.disconnect", metadata: %{reason: "node down"})
    {:noreply, %{state | session: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Voyager.PubSub, @pubsub_topic, event)
  end
end

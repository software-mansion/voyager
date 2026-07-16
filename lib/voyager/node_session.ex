defmodule Voyager.NodeSession do
  @moduledoc """
   GenServer holding the single active connection to a remote BEAM node.
  """

  use GenServer

  alias Voyager.NodeSession.Connectors.Distribution

  @default_connector Distribution

  defmodule Session do
    @moduledoc "Holds state for an active connection to a remote BEAM node."
    @type t :: %__MODULE__{
            node: atom(),
            node_name: String.t(),
            cookie: String.t(),
            connected_at: DateTime.t(),
            connector: module(),
            meta: map()
          }

    defstruct [:node, :node_name, :cookie, :connected_at, :connector, meta: %{}]
  end

  @pubsub_topic "node_session"

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Connects via the default distribution connector."
  @spec connect(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def connect(node_name, cookie, opts \\ []) do
    connect_via(@default_connector, node_name, cookie, opts)
  end

  @doc "Connects using an explicit `Voyager.NodeSession.Connector` module."
  @spec connect_via(module(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def connect_via(connector, node_name, cookie, opts \\ []) do
    GenServer.call(__MODULE__, {:connect, connector, node_name, cookie, opts}, 30_000)
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
    {:ok, %{session: nil, connecting: nil}}
  end

  @impl GenServer
  def handle_call(
        {:connect, _connector, _node_name, _cookie, _opts},
        _from,
        %{session: session} = state
      )
      when not is_nil(session) do
    {:reply, {:error, :already_connected}, state}
  end

  def handle_call(
        {:connect, _connector, _node_name, _cookie, _opts},
        _from,
        %{connecting: connecting} = state
      )
      when not is_nil(connecting) do
    {:reply, {:error, :already_connected}, state}
  end

  def handle_call({:connect, connector, node_name, cookie, opts}, from, state) do
    task =
      Task.Supervisor.async_nolink(Voyager.TaskSupervisor, fn ->
        connector.connect(node_name, cookie, opts)
      end)

    connecting = %{
      from: from,
      task_ref: task.ref,
      connector: connector,
      node_name: node_name,
      cookie: cookie
    }

    {:noreply, %{state | connecting: connecting}}
  end

  def handle_call(:disconnect, _from, %{session: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:disconnect, _from, %{session: session} = state) do
    Node.monitor(session.node, false)
    session.connector.disconnect(session.node, session.meta)
    unsubscribe(session.connector)
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
  def handle_info({ref, result}, %{connecting: %{task_ref: ref} = connecting} = state) do
    Process.demonitor(ref, [:flush])
    finish_connect(result, connecting, state)
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{connecting: %{task_ref: ref} = connecting} = state
      ) do
    GenServer.reply(connecting.from, {:error, {:connector_crashed, reason}})
    {:noreply, %{state | connecting: nil}}
  end

  # The remote node went down: clean up transport resources, then drop the session.
  def handle_info({:nodedown, node}, %{session: %Session{node: session_node} = session} = state)
      when node == session_node do
    Node.monitor(session.node, false)
    session.connector.disconnect(session.node, session.meta)
    drop_session(state, session, "node down")
  end

  # Any other message: ask the connector whether it signals its transport died
  # (e.g. an SSH tunnel dropping while the node itself is still up). If so the
  # transport is already gone, so drop the session without calling disconnect.
  def handle_info(msg, %{session: %Session{connector: connector, meta: meta} = session} = state) do
    if connector.teardown?(msg, meta) do
      Node.monitor(session.node, false)
      drop_session(state, session, "transport down")
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp finish_connect({:ok, node, meta}, connecting, state) do
    Node.monitor(node, true)
    subscribe(connecting.connector)

    session = %Session{
      node: node,
      node_name: connecting.node_name,
      cookie: connecting.cookie,
      connected_at: DateTime.utc_now(),
      connector: connecting.connector,
      meta: meta
    }

    broadcast({:node_connected, node})

    Voyager.Telemetry.dispatch!("voyager.node.connect",
      metadata: %{via: connecting.connector.name()}
    )

    GenServer.reply(connecting.from, :ok)
    {:noreply, %{state | session: session, connecting: nil}}
  end

  defp finish_connect({:error, _} = err, connecting, state) do
    GenServer.reply(connecting.from, err)
    {:noreply, %{state | connecting: nil}}
  end

  defp drop_session(state, session, reason) do
    unsubscribe(session.connector)
    broadcast({:nodedown, session.node})
    Voyager.Telemetry.dispatch!("voyager.node.disconnect", metadata: %{reason: reason})
    {:noreply, %{state | session: nil}}
  end

  defp subscribe(connector) do
    Enum.each(connector.subscriptions(), &Phoenix.PubSub.subscribe(Voyager.PubSub, &1))
  end

  defp unsubscribe(connector) do
    Enum.each(connector.subscriptions(), &Phoenix.PubSub.unsubscribe(Voyager.PubSub, &1))
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Voyager.PubSub, @pubsub_topic, event)
  end
end

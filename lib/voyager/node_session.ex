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

    defstruct [:node, :node_name, :cookie, :connected_at, connector: Distribution, meta: %{}]
  end

  @pubsub_topic "node_session"
  @connector_name_cache_key :connected_via

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def cached_connector_name do
    :persistent_term.get(@connector_name_cache_key, nil)
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
    cache_connector_name(nil)
    {:ok, %{session: nil}}
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

  def handle_call({:connect, connector, node_name, cookie, opts}, _from, %{session: nil} = state) do
    case safe_connect(connector, node_name, cookie, opts) do
      {:ok, node, meta} ->
        if Node.alive?(), do: Node.monitor(node, true)
        subscribe(connector)

        session = %Session{
          node: node,
          node_name: node_name,
          cookie: cookie,
          connected_at: DateTime.utc_now(),
          connector: connector,
          meta: meta
        }

        cache_connector_name(connector.name())

        broadcast({:node_connected, node})

        Voyager.Telemetry.dispatch!("voyager.node.connect",
          metadata: %{connected_via: connector.name()}
        )

        {:reply, :ok, %{state | session: session}}

      {:error, reason} = err ->
        Voyager.Telemetry.dispatch!("voyager.node.connect_failed",
          metadata: %{connected_via: connector.name(), reason: reason}
        )

        {:reply, err, state}
    end
  end

  def handle_call(:disconnect, _from, %{session: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:disconnect, _from, %{session: session} = state) do
    if Node.alive?(), do: Node.monitor(session.node, false)
    session.connector.disconnect(session.node, session.meta)
    unsubscribe(session.connector)
    cache_connector_name(nil)

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
  def handle_info({:nodedown, node}, %{session: %Session{node: session_node} = session} = state)
      when node == session_node do
    if Node.alive?(), do: Node.monitor(session.node, false)
    session.connector.disconnect(session.node, session.meta)
    drop_session(state, session, "node down")
  end

  def handle_info(msg, %{session: %Session{connector: connector, meta: meta} = session} = state) do
    if connector.teardown?(msg, meta) do
      if Node.alive?(), do: Node.monitor(session.node, false)
      drop_session(state, session, "transport down")
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp drop_session(state, session, reason) do
    unsubscribe(session.connector)
    cache_connector_name(nil)

    broadcast({:nodedown, session.node})
    Voyager.Telemetry.dispatch!("voyager.node.disconnect", metadata: %{reason: reason})
    {:noreply, %{state | session: nil}}
  end

  defp safe_connect(connector, node_name, cookie, opts) do
    connector.connect(node_name, cookie, opts)
  rescue
    error -> {:error, {:connector_crashed, error}}
  catch
    kind, reason -> {:error, {:connector_crashed, {kind, reason}}}
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

  defp cache_connector_name(via) do
    :persistent_term.put(@connector_name_cache_key, via)
  end
end

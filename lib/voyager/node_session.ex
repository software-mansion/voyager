defmodule Voyager.NodeSession do
  @moduledoc """
  GenServer holding the single active connection to a remote BEAM node.
  """

  use GenServer
  alias Voyager.Services.NodeConnector

  defmodule Session do
    @moduledoc "Holds state for an active connection to a remote BEAM node."

    @type t :: %__MODULE__{
            node: atom(),
            node_name: String.t(),
            cookie: String.t(),
            connected_at: DateTime.t()
          }

    defstruct [:node, :node_name, :cookie, :connected_at]
  end

  @pubsub_topic "node_session"

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Connects to a node."
  @spec connect(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def connect(node_name, cookie, opts \\ []) do
    GenServer.call(__MODULE__, {:connect, node_name, cookie, opts}, 15_000)
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
    {:ok, %{session: nil}}
  end

  @impl GenServer
  def handle_call({:connect, _node_name, _cookie, _opts}, _from, %{session: session} = state)
      when not is_nil(session) do
    {:reply, {:error, :already_connected}, state}
  end

  def handle_call({:connect, node_name, cookie, opts}, _from, %{session: nil} = state) do
    name_type = Keyword.get(opts, :name_type, :shortnames)

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
        {:reply, :ok, %{state | session: session}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:disconnect, _from, %{session: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:disconnect, _from, %{session: session} = state) do
    Node.monitor(session.node, false)
    NodeConnector.disconnect(session.node)
    broadcast({:node_disconnected, session.node})
    {:reply, :ok, %{state | session: nil}}
  end

  def handle_call(:current, _from, state) do
    {:reply, state.session, state}
  end

  def handle_call(:connected?, _from, state) do
    {:reply, match?(%Session{}, state.session), state}
  end

  @impl GenServer
  def handle_info({:nodedown, node}, %{session: %Session{node: session_node}} = state)
      when node == session_node do
    Node.monitor(node, false)
    broadcast({:nodedown, node})
    {:noreply, %{state | session: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Voyager.PubSub, @pubsub_topic, event)
  end
end

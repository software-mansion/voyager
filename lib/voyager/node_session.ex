defmodule Voyager.NodeSession do
  @moduledoc """
  GenServer holding the single active connection to a remote BEAM node.

  Language detection and node info are fetched asynchronously after connect so the
  caller is not blocked by multiple RPC round-trips.
  """

  use GenServer
  alias Voyager.RPC.ERPC

  defmodule Session do
    @type t :: %__MODULE__{
            node: atom(),
            node_name: String.t(),
            cookie: atom() | String.t(),
            connector: module(),
            language: module() | nil,
            connected_at: DateTime.t(),
            info: map()
          }

    defstruct [:node, :node_name, :cookie, :connector, :language, :connected_at, info: %{}]
  end

  @pubsub_topic "node_session"
  @languages [Voyager.Language.Elixir, Voyager.Language.Gleam, Voyager.Language.Erlang]
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Connects to a node. Returns :ok immediately; info is fetched in the background."
  def connect(node_name, cookie, opts \\ []) do
    GenServer.call(__MODULE__, {:connect, node_name, cookie, opts}, 15_000)
  end

  @doc "Disconnects from the current node."
  def disconnect do
    GenServer.call(__MODULE__, :disconnect)
  end

  @doc "Returns the current session map or nil."
  def current do
    GenServer.call(__MODULE__, :current)
  end

  def connected? do
    GenServer.call(__MODULE__, :connected?)
  end

  @doc "Lists nodes visible from the current node's cluster perspective."
  def cluster_nodes do
    GenServer.call(__MODULE__, :cluster_nodes)
  end

  @doc "Runs an RPC call on the current node."
  def rpc(mod, fun, args, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:rpc, mod, fun, args, timeout}, timeout + 1_000)
  end

  @doc "Returns the node info map fetched after connect, or {:error, :not_connected}."
  def node_info do
    GenServer.call(__MODULE__, :node_info)
  end

  @doc "PubSub topic for node session events."
  def topic, do: @pubsub_topic

  @impl GenServer
  def init(_opts) do
    {:ok, %{session: nil}}
  end

  @impl GenServer
  def handle_call({:connect, _node_name, _cookie, _opts}, _from, %{session: %{}} = state) do
    {:reply, {:error, :already_connected}, state}
  end

  def handle_call({:connect, node_name, cookie, opts}, _from, %{session: nil} = state) do
    connector = Keyword.get(opts, :connector, Voyager.Connector.Distribution)
    name_type = Keyword.get(opts, :name_type, :shortnames)

    case connector.connect(node_name, cookie, name_type: name_type) do
      :ok ->
        node = String.to_atom(node_name)
        Node.monitor(node, true)

        session = %Session{
          node: node,
          node_name: node_name,
          cookie: cookie,
          connector: connector,
          language: nil,
          connected_at: DateTime.utc_now(),
          info: %{}
        }

        broadcast({:node_connected, node})
        {:reply, :ok, %{state | session: session}, {:continue, :fetch_node_info}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:disconnect, _from, %{session: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:disconnect, _from, %{session: session} = state) do
    Node.monitor(session.node, false)
    session.connector.disconnect(session.node)
    broadcast({:node_disconnected, session.node})
    {:reply, :ok, %{state | session: nil}}
  end

  def handle_call(:current, _from, state) do
    {:reply, state.session, state}
  end

  def handle_call(:connected?, _from, state) do
    {:reply, state.session != nil, state}
  end

  def handle_call(:cluster_nodes, _from, %{session: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:cluster_nodes, _from, %{session: session} = state) do
    result = ERPC.call(session.node, :erlang, :nodes, [], 5_000)
    {:reply, result, state}
  end

  def handle_call({:rpc, _m, _f, _a, _t}, _from, %{session: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:rpc, mod, fun, args, timeout}, _from, %{session: session} = state) do
    result = ERPC.call(session.node, mod, fun, args, timeout)
    {:reply, result, state}
  end

  def handle_call(:node_info, _from, %{session: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:node_info, _from, %{session: session} = state) do
    {:reply, {:ok, session.info}, state}
  end

  @impl GenServer
  def handle_continue(:fetch_node_info, %{session: session} = state) when not is_nil(session) do
    session = session |> detect_language() |> fetch_info()
    broadcast({:node_info_updated, session.node, session.info})
    {:noreply, %{state | session: session}}
  end

  def handle_continue(:fetch_node_info, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:nodedown, node}, %{session: %{node: node}} = state) do
    broadcast({:nodedown, node})
    {:noreply, %{state | session: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp detect_language(%{node: node} = session) do
    apps =
      case ERPC.call(node, :application, :loaded_applications, [], 5_000) do
        {:ok, apps} -> apps
        {:error, _} -> []
      end

    language = Enum.find(@languages, Voyager.Language.Erlang, fn mod -> mod.detect?(apps) end)
    %{session | language: language}
  end

  defp fetch_info(%{node: node, language: language} = session) do
    %{session | info: Map.merge(fetch_common_info(node), language.info(node))}
  end

  defp fetch_common_info(node) do
    rpc = fn mod, fun, args ->
      case ERPC.call(node, mod, fun, args, 5_000) do
        {:ok, result} -> result
        {:error, _} -> nil
      end
    end

    %{
      process_count: rpc.(:erlang, :system_info, [:process_count]),
      memory: rpc.(:erlang, :memory, []),
      run_queue: rpc.(:erlang, :statistics, [:run_queue]),
      loaded_apps: rpc.(:application, :loaded_applications, []),
      node_name: rpc.(:erlang, :node, []),
      otp_release: rpc.(:erlang, :system_info, [:otp_release])
    }
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Voyager.PubSub, @pubsub_topic, event)
  end
end

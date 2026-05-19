defmodule Voyager.NodeSession do
  @moduledoc """
  GenServer holding the single active connection to a remote BEAM node.
  """

  use GenServer
  alias Voyager.RPC.ERPC

  defmodule Session do
    @moduledoc "Holds state for an active connection to a remote BEAM node."

    @type t :: %__MODULE__{
            node: atom(),
            node_name: String.t(),
            cookie: String.t(),
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

  @doc "Runs an RPC call on the remote node."
  @spec rpc(module(), atom(), list(), timeout()) :: {:ok, term()} | {:error, term()}
  def rpc(mod, fun, args, timeout \\ 5_000) do
    case current() do
      nil -> {:error, :not_connected}
      %Session{node: node} -> ERPC.call(node, mod, fun, args, timeout)
    end
  end

  @doc "Returns the node info map fetched after connect."
  @spec node_info() :: {:ok, map()} | {:error, :not_connected}
  def node_info do
    case current() do
      nil -> {:error, :not_connected}
      %Session{info: info} -> {:ok, info}
    end
  end

  @doc "Synchronously fetches volatile node statistics: process count, memory, and run queue."
  @spec fetch_stats() :: {:ok, map()} | {:error, :not_connected}
  def fetch_stats do
    case current() do
      nil ->
        {:error, :not_connected}

      %Session{node: node} ->
        stats =
          [
            {:process_count, :erlang, :system_info, [:process_count]},
            {:memory, :erlang, :memory, []},
            {:run_queue, :erlang, :statistics, [:run_queue]}
          ]
          |> Task.async_stream(
            fn {key, mod, fun, args} -> {key, ERPC.fetch(node, mod, fun, args)} end,
            timeout: :infinity
          )
          |> Enum.reduce(%{}, fn
            {:ok, {key, val}}, acc -> Map.put(acc, key, val)
            {:exit, _}, acc -> acc
          end)

        {:ok, stats}
    end
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
    {:reply, match?(%Session{}, state.session), state}
  end

  @impl GenServer
  def handle_continue(:fetch_node_info, %{session: %Session{} = session} = state) do
    server = self()
    node = session.node

    Task.Supervisor.start_child(Voyager.TaskSupervisor, fn ->
      updated = session |> detect_language() |> fetch_info()
      send(server, {:node_info_fetched, node, updated})
    end)

    {:noreply, state}
  end

  def handle_continue(:fetch_node_info, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(
        {:node_info_fetched, node, updated_session},
        %{session: %Session{node: session_node}} = state
      )
      when node == session_node do
    broadcast({:node_info_updated, node, updated_session.info})
    {:noreply, %{state | session: updated_session}}
  end

  def handle_info({:node_info_fetched, _node, _session}, state) do
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, %{session: %Session{node: session_node}} = state)
      when node == session_node do
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
    common_task = Task.async(fn -> fetch_common_info(node) end)
    lang_task = Task.async(fn -> language.info(node) end)

    info =
      Map.merge(
        Task.await(common_task, 10_000),
        Task.await(lang_task, 10_000)
      )

    %{session | info: info}
  end

  defp fetch_common_info(node) do
    [
      {:process_count, :erlang, :system_info, [:process_count]},
      {:memory, :erlang, :memory, []},
      {:run_queue, :erlang, :statistics, [:run_queue]},
      {:loaded_apps, :application, :loaded_applications, []},
      {:node_name, :erlang, :node, []},
      {:otp_release, :erlang, :system_info, [:otp_release]}
    ]
    |> Task.async_stream(
      fn {key, mod, fun, args} -> {key, ERPC.fetch(node, mod, fun, args)} end,
      timeout: :infinity
    )
    |> Enum.reduce(%{}, fn
      {:ok, {key, val}}, acc -> Map.put(acc, key, val)
      {:exit, _reason}, acc -> acc
    end)
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Voyager.PubSub, @pubsub_topic, event)
  end
end

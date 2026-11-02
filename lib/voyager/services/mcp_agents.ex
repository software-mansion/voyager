defmodule Voyager.Services.McpAgents do
  @moduledoc """
  The one place the sidebar, settings and tray ask about AI agents: whether the MCP
  server runs, which agents this machine has, and which called the server in the last
  ten minutes. Broadcasts `{:mcp_agents, t()}` on `topic/0` whenever that changes.

  Agent detection reads the filesystem, so it only reruns on `refresh/0` or a URL change.
  """

  use GenServer

  alias Voyager.MCP
  alias Voyager.Services.McpClients

  require Logger

  defstruct state: :off, url: nil, agents: [], connected: []

  @type connection :: %{client: String.t(), version: String.t() | nil, last_seen: DateTime.t()}
  @type agent :: %{
          id: McpClients.id() | nil,
          name: String.t(),
          command: String.t() | nil,
          link: String.t() | nil,
          config_path: String.t() | nil,
          installed?: boolean(),
          added?: boolean(),
          connection: connection() | nil
        }
  @typedoc """
  `agents` are the ones found on this machine or connected, in display order;
  `connected` is the subset with a connection, most recent call first.
  """
  @type t :: %__MODULE__{
          state: :off | :on | :connected,
          url: String.t() | nil,
          agents: [agent()],
          connected: [agent()]
        }

  @topic "mcp_agents"
  @ttl_seconds 600
  @prune_interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec get() :: t()
  def get do
    GenServer.call(__MODULE__, :get)
  catch
    :exit, _ -> %__MODULE__{url: MCP.info().url}
  end

  @doc "Rescans this machine for agents and their configs."
  @spec refresh() :: :ok
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @spec seen(map() | nil) :: :ok
  # Anubis reports a session it restored after a server restart under this placeholder name.
  def seen(%{"name" => "auto-recovered"}), do: :ok

  def seen(%{"name" => name} = client_info) when is_binary(name) do
    GenServer.cast(__MODULE__, {:seen, name, client_info["version"]})
  end

  def seen(_client_info), do: :ok

  @doc false
  # Anubis defines `handle_request/2` in its own `__before_compile__`, so wrapping it needs a later hook.
  defmacro track_requests(_env) do
    quote do
      def handle_request(request, frame) do
        unquote(__MODULE__).seen(frame.context.client_info)
        super(request, frame)
      end
    end
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Voyager.PubSub, MCP.topic())
    schedule_prune()
    state = %{server: MCP.info(), clients: [], connections: %{}, snapshot: nil}
    {:ok, state, {:continue, :detect}}
  end

  @impl true
  def handle_continue(:detect, state), do: {:noreply, detect(state)}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.snapshot, state}

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, detect(state)}

  def handle_cast({:seen, name, version}, state) do
    if not Map.has_key?(state.connections, name),
      do: Logger.info("MCP client connected: #{name} #{version}")

    connection = %{client: name, version: version, last_seen: DateTime.utc_now()}
    {:noreply, publish(put_in(state.connections[name], connection))}
  end

  @impl true
  def handle_info({:mcp_status, server}, state) do
    state = %{state | server: server}

    # `added?` compares each config against the URL.
    if server.url == state.snapshot.url,
      do: {:noreply, publish(state)},
      else: {:noreply, detect(state)}
  end

  def handle_info(:prune, state) do
    schedule_prune()
    cutoff = DateTime.add(DateTime.utc_now(), -@ttl_seconds)
    fresh = Map.filter(state.connections, fn {_, c} -> DateTime.after?(c.last_seen, cutoff) end)
    {:noreply, publish(%{state | connections: fresh})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp detect(state), do: publish(%{state | clients: McpClients.all(state.server.url)})

  defp publish(state) do
    snapshot = snapshot(state)

    if snapshot != state.snapshot,
      do: Phoenix.PubSub.broadcast(Voyager.PubSub, @topic, {:mcp_agents, snapshot})

    %{state | snapshot: snapshot}
  end

  defp snapshot(%{server: server, clients: clients, connections: connections}) do
    by_id = connections |> Map.values() |> Enum.group_by(&McpClients.match(&1.client))

    known =
      clients
      |> Enum.map(&Map.put(&1, :connection, latest(Map.get(by_id, &1.id, []))))
      |> Enum.filter(&(&1.installed? or &1.added? or &1.connection != nil))

    unknown =
      by_id
      |> Map.get(nil, [])
      |> Enum.sort_by(& &1.client)
      |> Enum.map(&unknown_agent/1)

    agents = known ++ unknown

    connected =
      agents
      |> Enum.filter(& &1.connection)
      |> Enum.sort_by(& &1.connection.last_seen, {:desc, DateTime})

    %__MODULE__{
      state: state(server.alive?, connected),
      url: server.url,
      agents: agents,
      connected: connected
    }
  end

  defp state(false, _connected), do: :off
  defp state(true, []), do: :on
  defp state(true, _connected), do: :connected

  defp unknown_agent(connection) do
    %{
      id: nil,
      name: connection.client,
      command: nil,
      link: nil,
      config_path: nil,
      installed?: false,
      added?: false,
      connection: connection
    }
  end

  defp latest(connections), do: Enum.max_by(connections, & &1.last_seen, DateTime, fn -> nil end)

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_interval_ms)
end

defmodule Voyager.Services.McpAgents do
  @moduledoc """
  The one place the sidebar, settings and tray ask about AI agents: whether the MCP
  server runs, which agents Voyager supports, and which are calling its tools.
  Broadcasts `{:mcp_agents, t()}` on `topic/0` whenever that changes.

  Agent detection reads the filesystem, so it only reruns on `refresh/0` or a URL change.
  """

  use GenServer

  alias Voyager.MCP
  alias Voyager.Services.McpClients

  defstruct state: :off, url: nil, agents: [], in_use: []

  @type activity :: %{
          client: String.t(),
          version: String.t() | nil,
          status: :active | :recent
        }
  @type agent :: %{
          id: McpClients.id() | nil,
          name: String.t(),
          command: String.t() | nil,
          link: String.t() | nil,
          config_path: String.t() | nil,
          found?: boolean(),
          added?: boolean(),
          activity: activity() | nil
        }
  @typedoc """
  `agents` are every supported agent, then unsupported ones in use, in display order;
  `in_use` is the subset with activity, active ones first.
  """
  @type t :: %__MODULE__{
          state: :off | :on | :in_use,
          url: String.t() | nil,
          agents: [agent()],
          in_use: [agent()]
        }

  @topic "mcp_agents"
  @recent_ms :timer.minutes(5)

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

  @doc """
  Marks the agent active until the calling process exits, then recently used for five
  minutes. Anubis runs every request in its own task, so call it from that task.
  """
  @spec tool_call_started(map() | nil) :: :ok
  # Anubis reports a session it restored after a server restart under this placeholder name.
  def tool_call_started(%{"name" => "auto-recovered"}), do: :ok

  def tool_call_started(%{"name" => name} = client_info) when is_binary(name) do
    GenServer.cast(__MODULE__, {:call_started, name, client_info["version"], self()})
  end

  def tool_call_started(_client_info), do: :ok

  @doc false
  # Anubis defines `handle_request/2` in its own `__before_compile__`, so wrapping it needs a later hook.
  defmacro track_tool_calls(_env) do
    quote do
      def handle_request(%{"method" => "tools/call"} = request, frame) do
        unquote(__MODULE__).tool_call_started(frame.context.client_info)
        super(request, frame)
      end

      def handle_request(request, frame), do: super(request, frame)
    end
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Voyager.PubSub, MCP.topic())
    state = %{server: MCP.info(), clients: [], calls: %{}, activity: %{}, snapshot: nil}
    {:ok, state, {:continue, :detect}}
  end

  @impl true
  def handle_continue(:detect, state), do: {:noreply, detect(state)}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.snapshot, state}

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, detect(state)}

  def handle_cast({:call_started, name, version, pid}, state) do
    ref = Process.monitor(pid)
    in_flight = get_in(state.activity, [name, :in_flight]) || 0
    entry = %{client: name, version: version, in_flight: in_flight + 1, ended_at: nil}

    state = %{
      state
      | calls: Map.put(state.calls, ref, name),
        activity: Map.put(state.activity, name, entry)
    }

    {:noreply, publish(state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {name, calls} = Map.pop(state.calls, ref)
    ended_at = System.monotonic_time(:millisecond)
    Process.send_after(self(), {:expire, name}, @recent_ms)

    activity =
      Map.update!(state.activity, name, &%{&1 | in_flight: &1.in_flight - 1, ended_at: ended_at})

    {:noreply, publish(%{state | calls: calls, activity: activity})}
  end

  def handle_info({:expire, name}, state) do
    if expired?(state.activity[name]),
      do: {:noreply, publish(%{state | activity: Map.delete(state.activity, name)})},
      else: {:noreply, state}
  end

  def handle_info({:mcp_status, server}, state) do
    state = %{state | server: server}

    # `added?` compares each config against the URL.
    if server.url == state.snapshot.url,
      do: {:noreply, publish(state)},
      else: {:noreply, detect(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp expired?(%{in_flight: 0, ended_at: ended_at}),
    do: System.monotonic_time(:millisecond) - ended_at >= @recent_ms

  defp expired?(_entry), do: false

  defp detect(state), do: publish(%{state | clients: McpClients.all(state.server.url)})

  defp publish(state) do
    snapshot = snapshot(state)

    if snapshot != state.snapshot,
      do: Phoenix.PubSub.broadcast(Voyager.PubSub, @topic, {:mcp_agents, snapshot})

    %{state | snapshot: snapshot}
  end

  defp snapshot(%{server: server, clients: clients, activity: activity}) do
    by_id =
      activity
      |> Map.values()
      |> Enum.map(&to_activity/1)
      |> Enum.group_by(&McpClients.match(&1.client))

    known = Enum.map(clients, &Map.put(&1, :activity, busiest(Map.get(by_id, &1.id, []))))

    unknown =
      by_id
      |> Map.get(nil, [])
      |> Enum.sort_by(& &1.client)
      |> Enum.map(&unknown_agent/1)

    agents = known ++ unknown

    in_use =
      agents
      |> Enum.filter(& &1.activity)
      |> Enum.sort_by(&(&1.activity.status != :active))

    %__MODULE__{
      state: state(server.alive?, in_use),
      url: server.url,
      agents: agents,
      in_use: in_use
    }
  end

  defp to_activity(%{client: client, version: version, in_flight: in_flight}) do
    %{client: client, version: version, status: if(in_flight > 0, do: :active, else: :recent)}
  end

  defp busiest(activities), do: Enum.min_by(activities, &(&1.status != :active), fn -> nil end)

  defp state(false, _in_use), do: :off
  defp state(true, []), do: :on
  defp state(true, _in_use), do: :in_use

  defp unknown_agent(activity) do
    %{
      id: nil,
      name: activity.client,
      command: nil,
      link: nil,
      config_path: nil,
      found?: false,
      added?: false,
      activity: activity
    }
  end
end

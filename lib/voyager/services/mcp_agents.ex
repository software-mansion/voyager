defmodule Voyager.Services.McpAgents do
  @moduledoc """
  Keeps one snapshot of the MCP server status, the coding agents Voyager can be added to, and
  the MCP clients that called a tool in the last five minutes. Broadcasts `{:mcp_agents, t()}`
  on `topic/0` whenever the snapshot changes.

  Scanning agents reads config files, so it only reruns on `refresh/0`, `install/1`, a URL
  change, or the first tool call from a client that was not recent.
  """

  use GenServer

  alias Voyager.MCP
  alias Voyager.Services.CodingAgents

  defstruct server: %{alive?: false, url: nil}, agents: [], recent: []

  @type recent :: %{
          name: String.t(),
          version: String.t() | nil,
          agent_id: CodingAgents.id() | nil
        }
  @type t :: %__MODULE__{
          server: %{alive?: boolean(), url: String.t() | nil},
          agents: [CodingAgents.agent()],
          recent: [recent()]
        }

  @topic "mcp_agents"
  @recent_ms :timer.minutes(5)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec get() :: t()
  def get, do: GenServer.call(__MODULE__, :get)

  @spec refresh() :: :ok
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @spec install(CodingAgents.id()) :: :ok | {:error, term()}
  def install(id), do: GenServer.call(__MODULE__, {:install, id})

  @spec remove(CodingAgents.id()) :: :ok | {:error, term()}
  def remove(id), do: GenServer.call(__MODULE__, {:remove, id})

  @spec tool_called(map() | nil) :: :ok
  # Anubis names a session it restored after a restart this way, so it is not a real client.
  def tool_called(%{"name" => "auto-recovered"}), do: :ok

  def tool_called(%{"name" => name} = client_info) when is_binary(name) do
    GenServer.cast(__MODULE__, {:tool_called, name, client_info["version"]})
  end

  def tool_called(_client_info), do: :ok

  @doc false
  # Anubis defines `handle_request/2` in its own `__before_compile__`, so wrapping it needs a later one.
  defmacro track_tool_calls(_env) do
    quote do
      def handle_request(%{"method" => "tools/call"} = request, frame) do
        unquote(__MODULE__).tool_called(frame.context.client_info)
        super(request, frame)
      end

      def handle_request(request, frame), do: super(request, frame)
    end
  end

  @impl true
  def init(nil) do
    Phoenix.PubSub.subscribe(Voyager.PubSub, MCP.topic())
    state = %{server: MCP.info(), agents: [], calls: %{}, snapshot: %__MODULE__{}}
    {:ok, state, {:continue, :scan}}
  end

  @impl true
  def handle_continue(:scan, state), do: {:noreply, state |> scan() |> publish()}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.snapshot, state}

  def handle_call({:install, id}, _from, state) do
    {:reply, CodingAgents.install(id, state.server.url), state |> scan() |> publish()}
  end

  def handle_call({:remove, id}, _from, state) do
    {:reply, CodingAgents.remove(id), state |> scan() |> publish()}
  end

  @impl true
  def handle_cast(:refresh, state), do: {:noreply, state |> scan() |> publish()}

  def handle_cast({:tool_called, name, version}, state) do
    ref = make_ref()
    Process.send_after(self(), {:expire, name, ref}, @recent_ms)
    new_client? = not Map.has_key?(state.calls, name)
    call = %{version: version, ref: ref}
    state = %{state | calls: Map.put(state.calls, name, call)}
    state = if new_client?, do: scan(state), else: state
    {:noreply, publish(state)}
  end

  @impl true
  def handle_info({:expire, name, ref}, state) do
    case state.calls do
      %{^name => %{ref: ^ref}} ->
        {:noreply, publish(%{state | calls: Map.delete(state.calls, name)})}

      _calls ->
        {:noreply, state}
    end
  end

  def handle_info({:mcp_status, server}, state) do
    state = if server.url == state.server.url, do: state, else: scan(%{state | server: server})
    {:noreply, publish(%{state | server: server})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp scan(state), do: %{state | agents: CodingAgents.scan(state.server.url)}

  defp publish(state) do
    snapshot = %__MODULE__{
      server: state.server,
      agents: state.agents,
      recent: recent(state.calls)
    }

    if snapshot != state.snapshot,
      do: Phoenix.PubSub.broadcast(Voyager.PubSub, @topic, {:mcp_agents, snapshot})

    %{state | snapshot: snapshot}
  end

  defp recent(calls) do
    calls
    |> Enum.sort_by(fn {name, _call} -> name end)
    |> Enum.map(fn {name, call} ->
      %{name: name, version: call.version, agent_id: CodingAgents.match(name)}
    end)
  end
end

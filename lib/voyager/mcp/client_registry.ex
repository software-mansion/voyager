defmodule Voyager.MCP.ClientRegistry do
  @moduledoc """
  Remembers which MCP clients have talked to the server in the last five minutes,
  keyed by the name from their `initialize` `clientInfo`, and broadcasts
  `{:mcp_clients, [client()]}` on `topic/0` whenever that list changes.
  """

  use GenServer

  require Logger

  @type client :: %{name: String.t(), version: String.t() | nil, last_seen: DateTime.t()}

  @topic "mcp_clients"
  @ttl_seconds 300
  @prune_interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec seen(map() | nil) :: :ok
  # Anubis reports a session it restored after a server restart under this placeholder name.
  def seen(%{"name" => "auto-recovered"}), do: :ok

  def seen(%{"name" => name} = client_info) when is_binary(name) do
    GenServer.cast(__MODULE__, {:seen, name, client_info["version"]})
  end

  def seen(_client_info), do: :ok

  @spec all() :: [client()]
  def all do
    GenServer.call(__MODULE__, :all)
  catch
    :exit, _ -> []
  end

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
  def init(clients) do
    schedule_prune()
    {:ok, clients}
  end

  @impl true
  def handle_cast({:seen, name, version}, clients) do
    if not Map.has_key?(clients, name),
      do: Logger.info("MCP client connected: #{name} #{version}")

    clients =
      Map.put(clients, name, %{name: name, version: version, last_seen: DateTime.utc_now()})

    broadcast(clients)
    {:noreply, clients}
  end

  @impl true
  def handle_info(:prune, clients) do
    schedule_prune()
    cutoff = DateTime.add(DateTime.utc_now(), -@ttl_seconds)

    fresh =
      Map.filter(clients, fn {_name, client} -> DateTime.after?(client.last_seen, cutoff) end)

    if map_size(fresh) != map_size(clients), do: broadcast(fresh)
    {:noreply, fresh}
  end

  @impl true
  def handle_call(:all, _from, clients), do: {:reply, Map.values(clients), clients}

  defp broadcast(clients),
    do: Phoenix.PubSub.broadcast(Voyager.PubSub, @topic, {:mcp_clients, Map.values(clients)})

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_interval_ms)
end

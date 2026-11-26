defmodule Voyager.Services.DemoNode do
  @moduledoc """
  Runs the bundled demo node as a `:peer` of the Voyager VM.

  The demo node stops when the user disconnects from it, connects to another node, or does not
  connect within the idle timeout. It halts with the Voyager VM, because a `:standard_io` peer
  halts when its stdin closes.
  """

  use GenServer

  alias Voyager.NodeSession
  alias Voyager.Queries.Connections, as: ConnectionQueries
  alias Voyager.Queries.SshConnections, as: SshConnectionQueries
  alias Voyager.Settings

  require Logger

  @dismissed_key :demo_dismissed
  @pubsub_topic "demo_node"
  @name ~c"voyager_demo"
  @host ~c"127.0.0.1"
  @node_name "#{@name}@#{@host}"
  @idle_timeout :timer.minutes(5)
  @load_timeout :timer.seconds(30)

  @type params :: %{node_name: String.t(), cookie: String.t()}
  @type offer :: :hidden | :sticky | :dismissible

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  How to offer the demo: `:sticky` while there are no saved connections, whether dismissed or
  not; `:dismissible` once there are some, until dismissed.
  """
  @spec offer() :: offer()
  def offer do
    cond do
      not saved_connections?() -> :sticky
      Settings.get(@dismissed_key) == true -> :hidden
      Settings.locked?(@dismissed_key) -> :sticky
      true -> :dismissible
    end
  end

  @spec dismiss() :: :ok | {:error, term()}
  def dismiss do
    with {:ok, _setting} <- Settings.put(@dismissed_key, true),
         do: Voyager.Telemetry.dispatch!("voyager.demo.dismiss")
  end

  @doc """
  Boots a fresh demo node, replacing one already running, and returns its connect params.
  Blocks until the node is up.
  """
  @spec start() :: {:ok, params()} | {:error, term()}
  def start, do: GenServer.call(__MODULE__, :start, :infinity)

  @spec running?() :: boolean()
  def running?, do: GenServer.call(__MODULE__, :running?)

  @spec node_name() :: String.t()
  def node_name, do: @node_name

  @spec topic() :: String.t()
  def topic, do: @pubsub_topic

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())

    {:ok,
     %{
       peer_opts: Map.new(opts),
       peer: nil,
       node: nil,
       timer: nil,
       started_ms: nil
     }}
  end

  @impl GenServer
  def handle_call(:start, _from, state) do
    state = stop_demo(state, :restarted)
    cookie = :crypto.strong_rand_bytes(32) |> Base.encode32(padding: false)
    boot_ms = System.monotonic_time(:millisecond)

    case start_peer(state.peer_opts, cookie) do
      {:ok, peer, node} ->
        timer = :erlang.start_timer(@idle_timeout, self(), :idle_timeout)

        Voyager.Telemetry.dispatch!("voyager.demo.start",
          measurements: %{duration_ms: since(boot_ms)}
        )

        Phoenix.PubSub.broadcast(Voyager.PubSub, @pubsub_topic, :demo_started)

        state = %{
          state
          | peer: peer,
            node: node,
            timer: timer,
            started_ms: System.monotonic_time(:millisecond)
        }

        {:reply, {:ok, %{node_name: @node_name, cookie: cookie}}, state}

      {:error, reason} = error ->
        # :peer failure reasons embed the open_port env, which holds the cookie.
        Logger.error("Demo node failed to start")

        Voyager.Telemetry.dispatch!("voyager.demo.start_failed",
          measurements: %{duration_ms: since(boot_ms)},
          metadata: %{reason: failure(reason)}
        )

        {:reply, error, state}
    end
  end

  def handle_call(:running?, _from, state) do
    {:reply, state.peer != nil, state}
  end

  @impl GenServer
  def handle_info({:node_connected, node}, %{node: node} = state) do
    cancel_timer(state.timer)

    Voyager.Telemetry.dispatch!("voyager.demo.connect",
      measurements: %{time_to_connect_ms: since(state.started_ms)}
    )

    {:noreply, %{state | timer: nil}}
  end

  def handle_info({:node_connected, _other}, state) do
    {:noreply, stop_demo(state, :other_node)}
  end

  def handle_info({event, node, _reason}, %{node: node} = state)
      when event in [:node_disconnected, :nodedown] do
    {:noreply, stop_demo(state, event)}
  end

  def handle_info({:timeout, timer, :idle_timeout}, %{timer: timer} = state) do
    {:noreply, stop_demo(state, :idle_timeout)}
  end

  def handle_info({:EXIT, peer, _reason}, %{peer: peer} = state) do
    {:noreply, clear(state, :halted)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp saved_connections?, do: ConnectionQueries.any?() or SshConnectionQueries.any?()

  defp boot_args do
    args =
      with root when is_binary(root) <- System.get_env("RELEASE_ROOT"),
           vsn when is_binary(vsn) <- System.get_env("RELEASE_VSN") do
        # The release root has no bin/start.boot, the default boot file erl looks for.
        [
          "-boot",
          Path.join([root, "releases", vsn, "start_clean"]),
          "-boot_var",
          "RELEASE_LIB",
          Path.join(root, "lib")
        ]
      else
        _ -> ["-pa", Path.join(:code.lib_dir(:elixir), "ebin")]
      end

    Enum.map(args, &String.to_charlist/1)
  end

  defp start_peer(peer_opts, cookie) do
    opts =
      Map.merge(
        %{
          name: @name,
          host: @host,
          longnames: true,
          connection: :standard_io,
          args: [~c"-kernel", ~c"inet_dist_use_interface", ~c"{127,0,0,1}" | boot_args()],
          # argv is world-readable through ps; a process environment is readable only by its owner.
          env: [
            {~c"ERL_AFLAGS", ~c"-setcookie #{cookie}"}
          ]
        },
        peer_opts
      )

    with {:ok, peer, node} <- :peer.start_link(opts) do
      case load_demo(peer) do
        :ok ->
          {:ok, peer, node}

        error ->
          stop_peer(peer)
          error
      end
    end
  catch
    # :peer.start_link/1 exits instead of returning an error when the node fails to boot.
    :exit, reason -> {:error, reason}
  end

  defp load_demo(peer) do
    script = Application.app_dir(:voyager, "priv/demo/voyager_demo.exs")
    {:ok, _apps} = :peer.call(peer, :application, :ensure_all_started, [:elixir])
    _modules = :peer.call(peer, Code, :require_file, [script], @load_timeout)
    :ok = :peer.call(peer, VoyagerDemo, :start, [])
  catch
    kind, reason -> {:error, {:demo_load_failed, {kind, reason}}}
  end

  defp failure({:demo_load_failed, _reason}), do: :demo_load_failed
  defp failure(_reason), do: :boot_failed

  defp stop_demo(%{peer: nil} = state, _reason), do: state

  defp stop_demo(state, reason) do
    stop_peer(state.peer)
    clear(state, reason)
  end

  defp stop_peer(peer) do
    :peer.stop(peer)
  catch
    # The peer can exit on its own between a :nodedown and this stop.
    :exit, _reason -> :ok
  end

  defp clear(state, reason) do
    cancel_timer(state.timer)

    Voyager.Telemetry.dispatch!("voyager.demo.stop",
      measurements: %{duration_ms: since(state.started_ms)},
      metadata: %{reason: reason}
    )

    Phoenix.PubSub.broadcast(Voyager.PubSub, @pubsub_topic, {:demo_stopped, reason})

    %{state | peer: nil, node: nil, timer: nil, started_ms: nil}
  end

  defp since(ms), do: System.monotonic_time(:millisecond) - ms

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
end

defmodule Voyager.Services.DemoNode do
  @moduledoc """
  Runs the bundled demo node as a `:peer` of the Voyager VM. Available only in a release.

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
  @available_key {__MODULE__, :available?}
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

  @doc "Whether the demo can run: true only in a release."
  @spec available?() :: boolean()
  def available?, do: :persistent_term.get(@available_key, false)

  @doc """
  How to offer the demo: `:sticky` while there are no saved connections, whether dismissed or
  not; `:dismissible` once there are some, until dismissed.
  """
  @spec offer() :: offer()
  def offer do
    cond do
      not available?() -> :hidden
      not saved_connections?() -> :sticky
      Settings.get(@dismissed_key) == true -> :hidden
      Settings.locked?(@dismissed_key) -> :sticky
      true -> :dismissible
    end
  end

  @spec dismiss() :: :ok | {:error, term()}
  def dismiss do
    with {:ok, _setting} <- Settings.put(@dismissed_key, true), do: :ok
  end

  @doc """
  Boots a fresh demo node, replacing one already running, and returns its connect params.
  Blocks until the node is up.
  """
  @spec start() :: {:ok, params()} | {:error, term()}
  def start, do: GenServer.call(__MODULE__, :start, :infinity)

  @spec node_name() :: String.t()
  def node_name, do: @node_name

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())
    exec = Keyword.get_lazy(opts, :exec, &release_exec/0)
    :persistent_term.put(@available_key, exec != nil)

    {:ok,
     %{
       exec: exec,
       peer: nil,
       node: nil,
       timer: nil
     }}
  end

  @impl GenServer
  def handle_call(:start, _from, %{exec: nil} = state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call(:start, _from, state) do
    state = stop_demo(state)
    cookie = :crypto.strong_rand_bytes(32) |> Base.encode32(padding: false)

    case start_peer(state.exec, cookie) do
      {:ok, peer, node} ->
        timer = :erlang.start_timer(@idle_timeout, self(), :idle_timeout)
        state = %{state | peer: peer, node: node, timer: timer}
        {:reply, {:ok, %{node_name: @node_name, cookie: cookie}}, state}

      {:error, _reason} = error ->
        # :peer failure reasons embed the open_port env, which holds the cookie.
        Logger.error("Demo node failed to start")
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_info({:node_connected, node}, %{node: node} = state) do
    cancel_timer(state.timer)
    {:noreply, %{state | timer: nil}}
  end

  def handle_info({:node_connected, _other}, state) do
    {:noreply, stop_demo(state)}
  end

  def handle_info({event, node, _reason}, %{node: node} = state)
      when event in [:node_disconnected, :nodedown] do
    {:noreply, stop_demo(state)}
  end

  def handle_info({:timeout, timer, :idle_timeout}, %{timer: timer} = state) do
    {:noreply, stop_demo(state)}
  end

  def handle_info({:EXIT, peer, _reason}, %{peer: peer} = state) do
    {:noreply, clear(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp saved_connections?, do: ConnectionQueries.any?() or SshConnectionQueries.any?()

  defp release_exec do
    with root when is_binary(root) <- System.get_env("RELEASE_ROOT"),
         vsn when is_binary(vsn) <- System.get_env("RELEASE_VSN"),
         bindir when is_binary(bindir) <- System.get_env("BINDIR") do
      # The release root has no bin/start.boot, the default boot file erl looks for.
      args = [
        "-boot",
        Path.join([root, "releases", vsn, "start_clean"]),
        "-boot_var",
        "RELEASE_LIB",
        Path.join(root, "lib")
      ]

      {String.to_charlist(Path.join(bindir, "erl")), Enum.map(args, &String.to_charlist/1)}
    else
      _ -> nil
    end
  end

  defp start_peer(exec, cookie) do
    opts = %{
      name: @name,
      host: @host,
      longnames: true,
      connection: :standard_io,
      exec: exec,
      args: [~c"-kernel", ~c"inet_dist_use_interface", ~c"{127,0,0,1}"],
      # argv is world-readable through ps; a process environment is readable only by its owner.
      env: [
        {~c"ERL_AFLAGS", ~c"-setcookie #{cookie}"},
        {~c"ERL_EPMD_ADDRESS", ~c"127.0.0.1"}
      ]
    }

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

  defp stop_demo(%{peer: nil} = state), do: state

  defp stop_demo(state) do
    stop_peer(state.peer)
    clear(state)
  end

  defp stop_peer(peer) do
    :peer.stop(peer)
  catch
    # The peer can exit on its own between a :nodedown and this stop.
    :exit, _reason -> :ok
  end

  defp clear(state) do
    cancel_timer(state.timer)
    %{state | peer: nil, node: nil, timer: nil}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
end

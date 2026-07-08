defmodule Voyager.ProxyEpmd.TunnelRegistry do
  @moduledoc """
  Registry of active SSH-tunnelled remote nodes. Owns the `:proxy_epmd` ETS
  table mapping `node_name_charlist` -> `%{port, address, tunnel}` and monitors
  each registered tunnel pid so the entry is removed automatically when the
  tunnel dies.

  This is a custom registry built on `GenServer` and `:ets`, and does 
  not use Elixir's built-in `Registry` module under the hood.
  """

  use GenServer

  @table :proxy_epmd
  @pubsub_topic "tunnel_registry"

  def table_name, do: @table
  def topic, do: @pubsub_topic

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec register(charlist(), pos_integer(), :ssh.connection_ref()) :: :ok
  def register(node_key, local_port, conn) when is_list(node_key) and is_pid(conn) do
    GenServer.call(__MODULE__, {:register, node_key, local_port, conn})
  end

  @spec unregister(charlist()) :: :ok
  def unregister(node_key) when is_list(node_key) do
    GenServer.call(__MODULE__, {:unregister, node_key})
  end

  @spec unregister_by_tunnel(:ssh.connection_ref()) :: :ok
  def unregister_by_tunnel(conn) when is_pid(conn) do
    GenServer.call(__MODULE__, {:unregister_by_tunnel, conn})
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    {:ok, %{refs: %{}, keys: %{}}}
  end

  @impl true
  def handle_call({:register, node_key, local_port, conn}, _from, state) do
    state = drop_existing(state, node_key)
    ref = Process.monitor(conn)

    :ets.insert(@table, {node_key, %{port: local_port, address: {127, 0, 0, 1}, tunnel: conn}})

    state = %{
      state
      | refs: Map.put(state.refs, ref, node_key),
        keys: Map.put(state.keys, node_key, ref)
    }

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, node_key}, _from, state) do
    {:reply, :ok, drop_existing(state, node_key)}
  end

  @impl true
  def handle_call({:unregister_by_tunnel, conn}, _from, state) do
    node_key =
      :ets.foldl(
        fn
          {key, %{tunnel: ^conn}}, _acc -> key
          _entry, acc -> acc
        end,
        nil,
        @table
      )

    state = if node_key, do: drop_existing(state, node_key), else: state
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {node_key, refs} ->
        :ets.delete(@table, node_key)
        Phoenix.PubSub.broadcast(Voyager.PubSub, @pubsub_topic, {:tunnel_down, pid})
        {:noreply, %{state | refs: refs, keys: Map.delete(state.keys, node_key)}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp drop_existing(state, node_key) do
    case Map.pop(state.keys, node_key) do
      {nil, _} ->
        state

      {ref, keys} ->
        Process.demonitor(ref, [:flush])
        :ets.delete(@table, node_key)
        %{state | keys: keys, refs: Map.delete(state.refs, ref)}
    end
  end
end

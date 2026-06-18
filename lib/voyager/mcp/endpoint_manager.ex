defmodule Voyager.MCP.EndpointManager do
  @moduledoc """
  Owns and manages the dedicated Bandit HTTP endpoint serving the MCP transport.

  Port and IP are owned entirely by `Voyager.Settings` — this GenServer holds
  only the Bandit process reference. Every read of port/IP goes through the
  Settings service so config.exs overrides and DB persistence are always
  respected.

  ## Configuration (optional — overrides DB)

      config :voyager, :mcp_port, 4040
      config :voyager, :mcp_ip, {127, 0, 0, 1}
  """

  use GenServer

  alias Voyager.MCP.Router
  alias Voyager.Settings

  require Logger

  @type port_number :: pos_integer()
  @type state :: %{endpoint: pid() | nil, monitor: reference() | nil}

  @dynamic_supervisor Voyager.MCP.DynamicSupervisor

  @default_ip {127, 0, 0, 1}
  @default_port 4040
  @set_port_timeout 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Changes the listen port at runtime by binding Bandit to the new port.

  The new listener is started before the old one is stopped, so a failure to
  bind (e.g. the port is already in use) leaves the existing listener serving
  and returns `{:error, :port_in_use}` to the caller rather than crashing.
  """
  @spec set_port(port_number()) :: :ok | {:error, term()}
  def set_port(port) when is_integer(port) and port > 0 do
    GenServer.call(__MODULE__, {:set_port, port}, @set_port_timeout)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @impl true
  def init(_opts) do
    port = Settings.get(:mcp_port, @default_port)
    ip = Settings.get(:mcp_ip, @default_ip)
    state = %{endpoint: nil, monitor: nil}

    case start_endpoint(port, ip) do
      {:ok, pid} ->
        {:ok, monitor_endpoint(state, pid)}

      {:error, reason} ->
        # Don't take the whole MCP supervision tree down because the port is
        # busy at boot — start idle and let the user rebind via `set_port/1`.
        Logger.warning("MCP endpoint failed to start on port #{port}: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_call({:set_port, new_port}, _from, state) do
    if Settings.locked?(:mcp_port) do
      {:reply, {:error, :locked}, state}
    else
      do_set_port(new_port, state)
    end
  end

  defp do_set_port(new_port, state) do
    current_port = Settings.get(:mcp_port, @default_port)
    ip = Settings.get(:mcp_ip, @default_ip)

    if new_port == current_port and is_pid(state.endpoint) do
      {:reply, :ok, state}
    else
      swap_endpoint(new_port, ip, state)
    end
  end

  defp swap_endpoint(new_port, ip, state) do
    case start_endpoint(new_port, ip) do
      {:ok, pid} -> commit_endpoint(new_port, pid, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Persist before swapping so a DB failure leaves the old listener serving and
  # runtime/DB consistent. Only tear down the old listener once the new port is
  # durably stored.
  defp commit_endpoint(new_port, pid, state) do
    case Settings.put(:mcp_port, new_port) do
      {:ok, _} ->
        stop_endpoint(state)
        {:reply, :ok, monitor_endpoint(state, pid)}

      {:error, reason} ->
        DynamicSupervisor.terminate_child(@dynamic_supervisor, pid)
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, %{monitor: ref, endpoint: pid} = state) do
    Logger.warning("MCP endpoint #{inspect(pid)} went down: #{inspect(reason)}")
    {:noreply, %{state | endpoint: nil, monitor: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @spec start_endpoint(port_number(), :inet.ip_address()) ::
          {:ok, pid()} | {:error, :port_in_use | term()}
  defp start_endpoint(port, ip) do
    spec =
      Supervisor.child_spec({Bandit, plug: Router, port: port, ip: ip}, restart: :temporary)

    case DynamicSupervisor.start_child(@dynamic_supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, classify_error(reason)}
    end
  end

  @spec stop_endpoint(state()) :: :ok
  defp stop_endpoint(%{endpoint: pid, monitor: monitor}) when is_pid(pid) do
    if monitor, do: Process.demonitor(monitor, [:flush])
    DynamicSupervisor.terminate_child(@dynamic_supervisor, pid)
    :ok
  end

  defp stop_endpoint(_state), do: :ok

  @spec monitor_endpoint(state(), pid()) :: state()
  defp monitor_endpoint(state, pid) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    %{state | endpoint: pid, monitor: Process.monitor(pid)}
  end

  # Bandit/ThousandIsland bury the listen error deep in a nested
  # `:failed_to_start_child` shutdown tuple, so scan the term for `:eaddrinuse`.
  defp classify_error(reason) do
    if eaddrinuse?(reason), do: :port_in_use, else: reason
  end

  defp eaddrinuse?(:eaddrinuse), do: true
  defp eaddrinuse?(term) when is_tuple(term), do: term |> Tuple.to_list() |> eaddrinuse?()
  defp eaddrinuse?(term) when is_list(term), do: Enum.any?(term, &eaddrinuse?/1)
  defp eaddrinuse?(_term), do: false
end

defmodule Voyager.MCP.EndpointManager do
  @moduledoc """
  Owns and manages the dedicated Bandit HTTP endpoint serving the MCP transport.

  Started under the `Voyager.MCP` supervisor. Prefer the `Voyager.MCP` API
  (`Voyager.MCP.port/0`, `Voyager.MCP.set_port/1`, `Voyager.MCP.url/0`) over
  calling this module directly.

  ## Configuration

      config :voyager, Voyager.MCP.EndpointManager,
        ip: {127, 0, 0, 1},
        port: 4040
  """

  use GenServer

  alias Voyager.MCP.Router

  @type port_number :: pos_integer()

  @default_ip {127, 0, 0, 1}
  @set_port_timeout :timer.seconds(10)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current listen port, or `nil` when the endpoint is not running.
  """
  @spec port() :: port_number() | nil
  def port do
    case info() do
      %{port: port} -> port
      nil -> nil
    end
  end

  @doc """
  Returns the MCP Streamable HTTP endpoint URL, or `nil` when not running.
  """
  @spec url() :: String.t() | nil
  def url() do
    case info() do
      %{ip: ip, port: port} -> "http://#{format_host(ip)}:#{port}/mcp"
      nil -> nil
    end
  end

  @doc """
  Changes the listen port at runtime by restarting Bandit on the new port.

  Returns `:ok`, or `{:error, reason}` if the port could not be bound (the old
  port is restored) or the listener is not running.
  """
  @spec set_port(port_number()) :: :ok | {:error, term()}
  def set_port(port) when is_integer(port) and port > 0 do
    GenServer.call(__MODULE__, {:set_port, port}, @set_port_timeout)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  Returns the running endpoint's `%{ip: ip, port: port}`, or `nil` when the
  endpoint is not running (i.e. MCP is inactive).
  """
  @spec info() :: %{ip: :inet.ip_address(), port: port_number()} | nil
  def info() do
    GenServer.call(__MODULE__, :info)
  catch
    :exit, _ -> nil
  end

  @impl true
  def init(opts) do
    config = Keyword.merge(config(), opts)
    port = Keyword.fetch!(config, :port)
    ip = Keyword.get(config, :ip, @default_ip)

    case start_endpoint(port, ip) do
      {:ok, pid} -> {:ok, %{port: port, ip: ip, endpoint: pid}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, %{ip: state.ip, port: state.port}, state}
  end

  def handle_call({:set_port, port}, _from, %{port: port} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:set_port, new_port}, _from, state) do
    :ok = stop_endpoint(state.endpoint)

    case start_endpoint(new_port, state.ip) do
      {:ok, pid} ->
        {:reply, :ok, %{state | port: new_port, endpoint: pid}}

      {:error, reason} ->
        # New port unavailable - restore the previous one.
        case start_endpoint(state.port, state.ip) do
          {:ok, pid} -> {:reply, {:error, reason}, %{state | endpoint: pid}}
          {:error, _} -> {:stop, reason, {:error, reason}, state}
        end
    end
  end

  # Bandit is linked to this GenServer. Stopping it with reason `:normal` is
  # ignored by the link (we don't trap exits), while an unexpected Bandit crash
  # propagates here and lets the `Voyager.MCP` supervisor restart the endpoint.
  defp start_endpoint(port, ip) do
    Bandit.start_link(plug: Router, port: port, ip: ip)
  end

  defp stop_endpoint(pid), do: Supervisor.stop(pid)

  defp config, do: Application.get_env(:voyager, __MODULE__, [])

  defp format_host({0, 0, 0, 0}), do: "127.0.0.1"
  defp format_host({127, 0, 0, 1}), do: "127.0.0.1"
  defp format_host(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
end

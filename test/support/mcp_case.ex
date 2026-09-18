defmodule Voyager.MCPCase do
  @moduledoc """
  Test case for MCP integration tests that start the MCP supervision tree.

  Sets up the SQL sandbox (shared mode) so `Voyager.Settings` and
  `Voyager.MCP.EndpointManager` can access the database.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false

      # MCP lifecycle tests intentionally bind busy ports and stop Bandit;
      # capture logs so expected warnings/errors don't clutter test output.
      @moduletag capture_log: true

      alias Voyager.MCP
      alias Voyager.MCP.EndpointManager
      alias Voyager.Repo
      alias Voyager.Settings

      import Voyager.MCPCase
    end
  end

  setup tags do
    Voyager.DataCase.setup_sandbox(tags)

    if tags[:skip_mcp] do
      stop_mcp()
      on_exit(fn -> stop_mcp() end)
      :ok
    else
      port = tags[:mcp_port] || unique_port()

      stop_mcp()

      on_exit(fn -> stop_mcp() end)

      {:ok, _} = Voyager.Settings.put(:mcp_port, port)
      start_supervised!({Voyager.MCP, enabled: true})

      %{mcp_port: port}
    end
  end

  @reserved_ports __MODULE__.PortReservations
  @max_port_attempts 50

  @doc """
  Asks the kernel for a free TCP port and reserves it for this test run.

  Remapping `System.unique_integer/1` into a small range is not unique:
  remainders collide, and the chosen port may already be bound or sitting in
  TIME_WAIT. Binding port 0 lets the OS pick a free ephemeral port; a
  reservation set then prevents parallel callers from being handed the same
  port after the probe socket is closed.
  """
  @spec unique_port() :: pos_integer()
  def unique_port do
    ensure_port_reservations()
    reserve_free_port(@max_port_attempts)
  end

  defp reserve_free_port(0) do
    raise "could not reserve a free TCP port"
  end

  defp reserve_free_port(attempts) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    if reserve_port?(port) do
      port
    else
      reserve_free_port(attempts - 1)
    end
  end

  defp reserve_port?(port) do
    Agent.get_and_update(@reserved_ports, fn reserved ->
      if MapSet.member?(reserved, port) do
        {false, reserved}
      else
        {true, MapSet.put(reserved, port)}
      end
    end)
  end

  # Unlinked so the reservation set outlives individual test processes.
  defp ensure_port_reservations do
    case Agent.start(fn -> MapSet.new() end, name: @reserved_ports) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc false
  def stop_mcp do
    case Process.whereis(Voyager.MCP) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  end
end

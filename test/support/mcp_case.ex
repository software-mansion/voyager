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

  @doc "Returns a free TCP port picked by the kernel; the probe socket is closed before returning."
  @spec unique_port() :: pos_integer()
  def unique_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  @doc false
  def stop_mcp do
    case Process.whereis(Voyager.MCP) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  end
end

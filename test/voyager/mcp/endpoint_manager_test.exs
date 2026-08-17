defmodule Voyager.MCP.EndpointManagerTest do
  use Voyager.MCPCase

  alias Voyager.MCP
  alias Voyager.MCP.EndpointManager
  alias Voyager.Settings

  describe "info/0" do
    test "reports a running listener and endpoint URL", %{mcp_port: port} do
      assert %{alive?: true, url: url} = MCP.info()
      assert url == "http://127.0.0.1:#{port}/mcp"
    end

    test "maps 0.0.0.0 to 127.0.0.1 in the advertised URL", %{mcp_port: port} do
      assert {:ok, _} = Settings.put(:mcp_ip, {0, 0, 0, 0})

      assert %{url: url} = MCP.info()
      assert url == "http://127.0.0.1:#{port}/mcp"
    end
  end

  describe "boot" do
    @tag skip_mcp: true
    test "starts idle when the configured port is already in use" do
      port = unique_port()
      {:ok, socket} = :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(socket) end)

      {:ok, _} = Settings.put(:mcp_port, port)
      start_supervised!({Voyager.MCP, enabled: true})

      assert %{alive?: false, url: url} = MCP.info()
      assert url == "http://127.0.0.1:#{port}/mcp"
    end

    @tag skip_mcp: true
    test "stays idle on boot when mcp_enabled was persisted as false" do
      port = unique_port()
      {:ok, _} = Settings.put(:mcp_port, port)
      {:ok, _} = Settings.put(:mcp_enabled, false)
      start_supervised!({Voyager.MCP, enabled: true})

      assert %{alive?: false, url: url} = MCP.info()
      assert url == "http://127.0.0.1:#{port}/mcp"
    end

    @tag skip_mcp: true
    test "restarts the listener on boot after toggle persisted mcp_enabled: true" do
      port = unique_port()
      {:ok, _} = Settings.put(:mcp_port, port)
      {:ok, _} = Settings.put(:mcp_enabled, true)
      start_supervised!({Voyager.MCP, enabled: true})

      assert %{alive?: true, url: url} = MCP.info()
      assert url == "http://127.0.0.1:#{port}/mcp"
    end
  end

  describe "set_port/1" do
    test "restarts the endpoint on a new port", %{mcp_port: port} do
      new_port = port + 1
      assert :ok = MCP.set_port(new_port)
      assert Settings.get(:mcp_port) == new_port

      assert %{alive?: true, url: url} = MCP.info()
      assert url == "http://127.0.0.1:#{new_port}/mcp"
    end

    test "returns {:error, :locked} when the port is controlled by config", %{mcp_port: port} do
      Application.put_env(:voyager, :mcp_port, port)
      on_exit(fn -> Application.delete_env(:voyager, :mcp_port) end)

      assert {:error, :locked} = MCP.set_port(port + 1)

      assert %{alive?: true, url: url} = MCP.info()
      assert url == "http://127.0.0.1:#{port}/mcp"
    end

    test "returns {:error, :port_in_use} and keeps the current listener", %{mcp_port: port} do
      {:ok, socket} = :gen_tcp.listen(port + 1, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(socket) end)

      assert {:error, :port_in_use} = MCP.set_port(port + 1)

      assert %{alive?: true, url: url} = MCP.info()
      assert url == "http://127.0.0.1:#{port}/mcp"
    end

    test "persists a new port while the listener stays down after toggle", %{mcp_port: port} do
      assert {:ok, :stopped} = MCP.toggle()
      assert %{alive?: false} = MCP.info()

      new_port = port + 2
      assert :ok = MCP.set_port(new_port)
      assert Settings.get(:mcp_port) == new_port

      assert %{alive?: false, url: url} = MCP.info()
      assert url == "http://127.0.0.1:#{new_port}/mcp"
    end
  end

  describe "toggle/0" do
    test "stops and restarts the listener", %{mcp_port: port} do
      assert %{alive?: true} = MCP.info()

      assert {:ok, :stopped} = MCP.toggle()

      assert %{alive?: false, url: url} = MCP.info()
      assert url == "http://127.0.0.1:#{port}/mcp"

      assert {:ok, :running} = MCP.toggle()

      assert %{alive?: true, url: running_url} = MCP.info()
      assert running_url == "http://127.0.0.1:#{port}/mcp"
    end

    test "persists the running state to settings" do
      assert Settings.get(:mcp_enabled, true) == true

      assert {:ok, :stopped} = MCP.toggle()
      assert Settings.get(:mcp_enabled) == false

      assert {:ok, :running} = MCP.toggle()
      assert Settings.get(:mcp_enabled) == true
    end
  end

  describe "endpoint crash handling" do
    test "clears alive? when the Bandit process exits", %{mcp_port: port} do
      %{endpoint: pid} = :sys.get_state(EndpointManager)
      assert is_pid(pid)

      DynamicSupervisor.terminate_child(Voyager.MCP.DynamicSupervisor, pid)

      # Wait for EndpointManager to handle the Bandit DOWN message.
      _ = :sys.get_state(EndpointManager)

      assert %{alive?: false, url: url} = MCP.info()
      assert url == "http://127.0.0.1:#{port}/mcp"
    end
  end

  describe "telemetry" do
    @tag skip_mcp: true
    test "dispatches a start event with reason \"boot\" on successful boot" do
      parent = self()
      handler_id = "mcp-telemetry-boot-test-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:voyager, :mcp, :start],
        fn _event, _measurements, metadata, _config -> send(parent, metadata) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, _} = Settings.put(:mcp_port, unique_port())
      start_supervised!({Voyager.MCP, enabled: true})

      assert_receive %{reason: "boot"}
    end

    test "dispatches start/stop events on toggle" do
      parent = self()
      handler_id = "mcp-telemetry-test-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler_id,
        [[:voyager, :mcp, :start], [:voyager, :mcp, :stop]],
        fn event, _measurements, metadata, _config -> send(parent, {event, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, :stopped} = MCP.toggle()
      assert_receive {[:voyager, :mcp, :stop], %{reason: "manual toggle"}}

      assert {:ok, :running} = MCP.toggle()
      assert_receive {[:voyager, :mcp, :start], %{reason: "manual toggle"}}
    end

    test "dispatches a stop event when the endpoint crashes" do
      parent = self()
      handler_id = "mcp-telemetry-crash-test-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:voyager, :mcp, :stop],
        fn _event, _measurements, metadata, _config -> send(parent, metadata) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{endpoint: pid} = :sys.get_state(EndpointManager)
      DynamicSupervisor.terminate_child(Voyager.MCP.DynamicSupervisor, pid)

      # Wait for EndpointManager to handle the Bandit DOWN message and dispatch telemetry.
      _ = :sys.get_state(EndpointManager)

      assert_receive %{reason: "crash"}
    end
  end

  describe "status broadcasts" do
    test "broadcasts on toggle", %{mcp_port: port} do
      Phoenix.PubSub.subscribe(Voyager.PubSub, MCP.topic())

      assert {:ok, :stopped} = MCP.toggle()
      assert_receive {:mcp_status, %{alive?: false, url: url}}
      assert url == "http://127.0.0.1:#{port}/mcp"

      assert {:ok, :running} = MCP.toggle()
      assert_receive {:mcp_status, %{alive?: true, url: ^url}}
    end

    test "broadcasts when the endpoint crashes" do
      Phoenix.PubSub.subscribe(Voyager.PubSub, MCP.topic())

      %{endpoint: pid} = :sys.get_state(EndpointManager)
      assert is_pid(pid)
      DynamicSupervisor.terminate_child(Voyager.MCP.DynamicSupervisor, pid)

      assert_receive {:mcp_status, %{alive?: false}}
    end
  end
end

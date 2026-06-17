defmodule Voyager.MCP.EndpointManagerTest do
  use ExUnit.Case, async: false

  alias Voyager.MCP

  setup do
    case Process.whereis(Voyager.MCP) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end

    on_exit(fn ->
      case Process.whereis(Voyager.MCP) do
        nil -> :ok
        pid -> Supervisor.stop(pid)
      end
    end)

    :ok
  end

  test "set_port/1 restarts the endpoint on a new port" do
    _pid =
      start_supervised!({Voyager.MCP, enabled: true, endpoint: [port: 54_041]})

    assert MCP.port() == 54_041
    assert MCP.url() == "http://127.0.0.1:54041/mcp"

    assert :ok = MCP.set_port(54_042)
    assert MCP.port() == 54_042
    assert MCP.url() == "http://127.0.0.1:54042/mcp"
  end
end

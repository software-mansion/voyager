defmodule Voyager.MCPCaseTest do
  use ExUnit.Case, async: true

  alias Voyager.MCPCase

  test "unique_port/0 returns a bindable port" do
    port = MCPCase.unique_port()
    assert port > 0

    assert {:ok, socket} = :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}])
    :ok = :gen_tcp.close(socket)
  end

  test "unique_port/0 does not reuse a port during the test run" do
    ports = Enum.map(1..20, fn _ -> MCPCase.unique_port() end)
    assert ports == Enum.uniq(ports)
  end

  test "unique_port/0 is unique across concurrent callers" do
    ports =
      1..20
      |> Task.async_stream(fn _ -> MCPCase.unique_port() end, timeout: :infinity)
      |> Enum.map(fn {:ok, port} -> port end)

    assert ports == Enum.uniq(ports)
  end

  test "unique_port/0 does not return a port that is already listening" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, busy_port} = :inet.port(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)

    ports = MapSet.new(Enum.map(1..30, fn _ -> MCPCase.unique_port() end))
    refute MapSet.member?(ports, busy_port)
  end
end

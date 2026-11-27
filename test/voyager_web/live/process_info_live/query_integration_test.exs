defmodule VoyagerWeb.ProcessInfoLive.QueryIntegrationTest do
  use Voyager.ErpcCase

  alias Voyager.Pid
  alias VoyagerWeb.Formatters

  test "parses a normal-form string of a connected node locally", %{node: peer_node} do
    pid = :erpc.call(peer_node, :erlang, :whereis, [:code_server])
    pid_string = Formatters.format_pid(pid)

    assert pid_string =~ ~r/^<[1-9]/

    # The mock is still the configured erpc impl and has no expectations, so
    # a remote round trip here would fail the test.
    assert Pid.resolve(peer_node, pid_string) == {:ok, pid}
    assert Pid.resolve(:other@nohost, pid_string) == {:error, :invalid_pid}

    [first, second] = for _n <- 1..2, do: spawn(fn -> :ok end)

    Mox.expect(Voyager.ErpcMock, :call, fn ^peer_node, :lists, :map, _args, _timeout ->
      [first, second]
    end)

    assert Pid.resolve_all(peer_node, ["<0.45.6>", pid_string, "<0.45.7>"]) ==
             {:ok, [first, pid, second]}
  end
end

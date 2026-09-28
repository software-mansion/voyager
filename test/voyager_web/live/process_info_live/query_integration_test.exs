defmodule VoyagerWeb.ProcessInfoLive.QueryIntegrationTest do
  # async: false because starting distribution renames the local node for the
  # whole VM; sync modules run after the async ones that assert on nonode.
  use ExUnit.Case, async: false

  alias VoyagerWeb.Formatters
  alias VoyagerWeb.ProcessInfoLive.Query

  @moduletag :integration

  test "parses a normal-form string of a connected node locally" do
    unless Node.alive?() do
      {_output, 0} = System.cmd("epmd", ["-daemon"])

      {:ok, _pid} =
        :net_kernel.start(:"voyager_test_#{System.unique_integer([:positive])}", %{
          name_domain: :shortnames
        })

      on_exit(fn -> :net_kernel.stop() end)
    end

    {:ok, peer, peer_node} =
      :peer.start(%{name: :"voyager_peer_#{System.unique_integer([:positive])}"})

    on_exit(fn -> :peer.stop(peer) end)

    pid = :erpc.call(peer_node, :erlang, :whereis, [:code_server])
    pid_string = Formatters.format_pid(pid)

    assert pid_string =~ ~r/^<[1-9]/

    # The mock is still the configured erpc impl and has no expectations, so
    # a remote round trip here would fail the test.
    assert Query.resolve_pid(peer_node, pid_string) == {:ok, pid}
    assert Query.resolve_pid(:other@nohost, pid_string) == {:error, :invalid_pid}
  end
end

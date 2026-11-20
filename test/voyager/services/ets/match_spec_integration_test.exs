defmodule Voyager.Services.Ets.MatchSpecIntegrationTest do
  # async: false because starting distribution renames the local node for the whole VM.
  use ExUnit.Case, async: false

  alias Voyager.Agent
  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.MatchSpec

  @moduletag :integration

  setup do
    unless Node.alive?() do
      {_output, 0} = System.cmd("epmd", ["-daemon"])

      {:ok, _pid} =
        :net_kernel.start(:"voyager_test_#{System.unique_integer([:positive])}", %{
          name_domain: :shortnames
        })

      on_exit(fn -> :net_kernel.stop() end)
    end

    {:ok, peer, node} =
      :peer.start(%{name: :"voyager_peer_#{System.unique_integer([:positive])}"})

    on_exit(fn -> :peer.stop(peer) end)

    Mox.stub_with(Voyager.ErpcMock, Voyager.Erpc.Impl)
    :ok = Agent.install(node)

    %{node: node}
  end

  test "selects with the atoms the node already has", %{node: node} do
    assert {:ok, spec} = MatchSpec.parse("[{{{loaded, '$1'}, '_'}, [], ['$1']}]")
    assert {:ok, %{records: apps}} = Fetch.select_spec(node, :ac_tab, spec, 100)
    assert :kernel in apps
  end

  test "refuses an atom the node lacks, without creating it there", %{node: node} do
    name = "voyager_no_such_atom_#{System.unique_integer([:positive])}"

    assert {:ok, spec} = MatchSpec.parse("[{{{loaded, #{name}}, '_'}, [], ['$_']}]")
    assert Fetch.select_spec(node, :ac_tab, spec, 100) == {:error, {:unknown_atom, name}}

    assert {:exception, :badarg, _stack} =
             catch_error(:erpc.call(node, :erlang, :binary_to_existing_atom, [name]))
  end
end

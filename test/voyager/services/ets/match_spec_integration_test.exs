defmodule Voyager.Services.Ets.MatchSpecIntegrationTest do
  use Voyager.ErpcCase

  alias Voyager.Agent
  alias Voyager.Services.Ets.Fetch
  alias Voyager.Services.Ets.MatchSpec

  setup %{node: node} do
    Mox.stub_with(Voyager.ErpcMock, Voyager.Erpc.Impl)
    :ok = Agent.install(node)

    # An erpc call runs in a short-lived process, so the table passes to this heir when it exits.
    owner = Node.spawn(node, :timer, :sleep, [:infinity])
    :users = :erpc.call(node, :ets, :new, [:users, [:named_table, :public, {:heir, owner, nil}]])
    true = :erpc.call(node, :ets, :insert, [:users, [{:alice, :admin}, {:bob, :guest}]])
    :ok
  end

  test "selects with the atoms the node already has", %{node: node} do
    assert {:ok, spec} = MatchSpec.parse("[{{'$1', admin}, [], ['$1']}]")
    assert {:ok, %{records: [:alice]}} = Fetch.select_spec(node, :users, spec, 100)
  end

  test "refuses an atom the node lacks, without creating it there", %{node: node} do
    name = "voyager_no_such_atom_#{System.unique_integer([:positive])}"

    assert {:ok, spec} = MatchSpec.parse("[{{'$1', #{name}}, [], ['$1']}]")
    assert Fetch.select_spec(node, :users, spec, 100) == {:error, {:unknown_atom, name}}

    assert {:exception, :badarg, _stack} =
             catch_error(:erpc.call(node, :erlang, :binary_to_existing_atom, [name]))
  end
end

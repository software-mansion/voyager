defmodule VoyagerWeb.TermFormatterIdentifierTest do
  # async: false because the connected node's id and the PID format are cached for the whole VM.
  use ExUnit.Case, async: false

  import Mox
  import Voyager.TestUtils, only: [erl_eval: 1]

  alias Voyager.Pid
  alias VoyagerWeb.TermFormatter

  @node :"peer@127.0.0.1"

  setup :verify_on_exit!

  setup do
    format = Pid.cached_format()

    on_exit(fn ->
      Pid.put_node(nil)
      Pid.put_format(format)
    end)

    %{ids: [self(), make_ref(), hd(Port.list())]}
  end

  # NEW_PID_EXT: a pid of @node, which this VM cannot spawn without distribution.
  defp remote_pid(serial) do
    name = Atom.to_string(@node)

    :erlang.binary_to_term(
      <<131, 88, 119, byte_size(name), name::binary, serial::32, 0::32, 1::32>>
    )
  end

  defp connect(node_self) do
    expect(Voyager.ErpcMock, :call, fn @node, :erlang, :self, [], _timeout -> node_self end)
    Pid.put_node(@node)
  end

  defp assert_rebuilt_by_list_call(id) do
    assert {fun, text} = TermFormatter.identifier(id)
    assert fun in [:list_to_pid, :list_to_ref, :list_to_port]
    assert apply(:erlang, fun, [text]) == id
  end

  test "copies ids as list_to_* calls that rebuild them while no node is connected", %{ids: ids} do
    assert Pid.cached_node_id() == nil

    Enum.each(ids, &assert_rebuilt_by_list_call/1)
  end

  test "copies the connected node's ids as list_to_* calls that rebuild them", %{ids: ids} do
    connect(self())

    Enum.each(ids, &assert_rebuilt_by_list_call/1)
  end

  test "copies another node's ids as binary_to_term calls that rebuild them", %{ids: ids} do
    connect(remote_pid(1))

    for id <- ids do
      assert {:binary_to_term, binary} = TermFormatter.identifier(id)
      assert :erlang.binary_to_term(binary) == id
    end

    assert erl_eval(TermFormatter.copy_string(ids, syntax: :erlang)) == ids
    assert {^ids, _binding} = Code.eval_string(TermFormatter.copy_string(ids, syntax: :elixir))
  end

  test "renumbers the connected node's ids to 0 as its own shell does, whatever the display format" do
    connect(remote_pid(1))
    Pid.put_format(:distribution)
    pid = remote_pid(45)

    assert :erlang.pid_to_list(pid) == ~c"<#{Pid.cached_node_id()}.45.0>"
    assert TermFormatter.identifier(pid) == {:list_to_pid, ~c"<0.45.0>"}

    assert TermFormatter.copy_string({pid}, syntax: :elixir) ==
             ~s|{:erlang.list_to_pid(~c"<0.45.0>")}|

    assert TermFormatter.copy_string({pid}, syntax: :erlang) == ~s|{list_to_pid("<0.45.0>")}|
  end

  test "displays pids in the PID format setting in the Erlang syntax" do
    connect(remote_pid(1))
    pid = remote_pid(45)

    Pid.put_format(:local)
    assert TermFormatter.inspect({pid}, syntax: :erlang) == "{<0.45.0>}"

    Pid.put_format(:distribution)
    assert TermFormatter.inspect({pid}, syntax: :erlang) == "{<#{Pid.cached_node_id()}.45.0>}"
  end
end

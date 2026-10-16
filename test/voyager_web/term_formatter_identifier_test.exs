defmodule VoyagerWeb.TermFormatterIdentifierTest do
  # async: false because the connected node's id is cached for the whole VM.
  use ExUnit.Case, async: false

  import Mox

  alias Voyager.Pid
  alias VoyagerWeb.TermFormatter
  alias VoyagerWeb.TermTree

  @node :"peer@127.0.0.1"
  @other :"other@127.0.0.1"

  setup :verify_on_exit!

  setup do
    on_exit(fn -> Pid.put_node(nil) end)
  end

  defp node_atom(node) do
    name = Atom.to_string(node)
    <<119, byte_size(name), name::binary>>
  end

  defp pid_on(node, id),
    do: :erlang.binary_to_term(<<131, 88, node_atom(node)::binary, id::32, 0::32, 1::32>>)

  defp ref_on(node),
    do:
      :erlang.binary_to_term(
        <<131, 90, 3::16, node_atom(node)::binary, 1::32, 7::32, 8::32, 9::32>>
      )

  defp port_on(node),
    do: :erlang.binary_to_term(<<131, 120, node_atom(node)::binary, 5::64, 1::32>>)

  defp connect do
    expect(Voyager.ErpcMock, :call, fn @node, :erlang, :self, [], _timeout -> pid_on(@node, 1) end)

    Pid.put_node(@node)
  end

  test "numbers the connected node's pids, refs and ports as its own shell does" do
    connect()

    assert TermFormatter.identifier(pid_on(@node, 45)) == {:list_to_pid, "<0.45.0>"}
    assert TermFormatter.identifier(ref_on(@node)) == {:list_to_ref, "#Ref<0.9.8.7>"}
    assert TermFormatter.identifier(port_on(@node)) == {:list_to_port, "#Port<0.5>"}
  end

  test "leaves ids of other nodes in their distribution form" do
    connect()
    pid = pid_on(@other, 45)

    assert TermFormatter.identifier(pid) ==
             {:list_to_pid, List.to_string(:erlang.pid_to_list(pid))}
  end

  test "copies the connected node's ids in its local form in either syntax" do
    connect()
    term = {pid_on(@node, 45), ref_on(@node)}

    assert TermTree.copy_string(term, syntax: :elixir) ==
             ~s|{:erlang.list_to_pid(~c"<0.45.0>"), :erlang.list_to_ref(~c"#Ref<0.9.8.7>")}|

    assert TermTree.copy_string(term, syntax: :erlang) ==
             ~s|{list_to_pid("<0.45.0>"), list_to_ref("#Ref<0.9.8.7>")}|
  end

  test "copies pids in the local form whatever the display format" do
    format = Pid.cached_format()
    on_exit(fn -> Pid.put_format(format) end)
    connect()
    Pid.put_format(:distribution)

    assert TermTree.copy_string(pid_on(@node, 45), syntax: :elixir) =~ ~s|"<0.45.0>"|
  end

  test "displays pids in the PID format setting in the Erlang syntax" do
    format = Pid.cached_format()
    on_exit(fn -> Pid.put_format(format) end)
    connect()
    pid = pid_on(@node, 45)

    Pid.put_format(:local)
    assert TermFormatter.inspect({pid}, syntax: :erlang) == "{<0.45.0>}"

    Pid.put_format(:distribution)
    assert TermFormatter.inspect({pid}, syntax: :erlang) == "{#{:erlang.pid_to_list(pid)}}"
  end
end

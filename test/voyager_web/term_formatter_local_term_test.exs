defmodule VoyagerWeb.TermFormatterLocalTermTest do
  # async: false because the connected node's id and the PID format are cached for the whole VM.
  use ExUnit.Case, async: false

  import Mox
  import Voyager.TestUtils, only: [erl_eval: 1]

  alias Voyager.Pid
  alias VoyagerWeb.TermFormatter

  @node :"peer@127.0.0.1"
  @other_node :"other@127.0.0.1"

  # Tags from the external term format: https://www.erlang.org/doc/apps/erts/erl_ext_dist.html
  @version 131
  @new_pid_ext 88

  setup :verify_on_exit!

  setup do
    format = Pid.cached_format()

    on_exit(fn ->
      Pid.put_node(nil)
      Pid.put_format(format)
    end)

    %{ids: [self(), make_ref(), hd(Port.list())]}
  end

  # The pid `<N.x.y>` of `node`, which this VM cannot spawn without distribution.
  defp remote_pid(node, x, y \\ 0, creation \\ 1) do
    :erlang.binary_to_term(<<@version, new_pid_ext(node, x, y, creation)::binary>>)
  end

  defp new_pid_ext(node, x, y, creation) do
    <<@version, node_atom::binary>> = :erlang.term_to_binary(node)
    <<@new_pid_ext, node_atom::binary, x::32, y::32, creation::32>>
  end

  defp connect do
    expect(Voyager.ErpcMock, :call, fn @node, :erlang, :self, [], _timeout ->
      remote_pid(@node, 1)
    end)

    Pid.put_node(@node)
  end

  defp assert_pastes_back(term) do
    assert erl_eval(TermFormatter.copy_string(term, syntax: :erlang)) == term
    assert {^term, _binding} = Code.eval_string(TermFormatter.copy_string(term, syntax: :elixir))
  end

  defp rebuild(id) do
    {fun, arg} = TermFormatter.term_to_local_term(id)
    apply(:erlang, fun, [arg])
  end

  describe "term_to_local_term/1" do
    test "rebuilds pids, refs and ports with a binary_to_term call", %{ids: ids} do
      for id <- ids do
        assert {:binary_to_term, <<@version, _rest::binary>>} =
                 TermFormatter.term_to_local_term(id)

        assert rebuild(id) == id
      end
    end

    test "encodes the pid's node, X, Y and creation" do
      encoded = new_pid_ext(@node, 45, 7, 1)

      assert {:binary_to_term, <<@version, ^encoded::binary>>} =
               TermFormatter.term_to_local_term(remote_pid(@node, 45, 7))
    end

    test "rebuilds a pid with the same X and Y" do
      assert :c.pid(0, 123, 4) |> rebuild() |> :erlang.pid_to_list() == ~c"<0.123.4>"

      assert remote_pid(@node, 45, 7) |> rebuild() |> :erlang.pid_to_list() |> to_string() =~
               ~r/^<\d+\.45\.7>$/
    end

    test "keeps the node's creation, so a restarted node's pid is a different pid" do
      before_restart = remote_pid(@node, 45, 0, 1)
      after_restart = remote_pid(@node, 45, 0, 2)

      assert :erlang.pid_to_list(before_restart) == :erlang.pid_to_list(after_restart)
      assert rebuild(before_restart) == before_restart
      refute rebuild(before_restart) == after_restart
    end
  end

  describe "copy_string/2" do
    test "copies ids as binary_to_term calls", %{ids: ids} do
      assert TermFormatter.copy_string(ids, syntax: :erlang) =~ ~r/^\[binary_to_term\(<<131,/

      assert TermFormatter.copy_string(ids, syntax: :elixir) =~
               ~r/^\[:erlang.binary_to_term\(<<131,/
    end

    test "pastes back this node's ids while no node is connected", %{ids: ids} do
      assert Pid.cached_node_id() == nil

      assert_pastes_back(ids)
    end

    test "pastes back the connected node's and another node's pids", %{ids: ids} do
      connect()

      assert_pastes_back([remote_pid(@node, 45), remote_pid(@other_node, 45) | ids])
    end

    test "copies the same text whatever the PID format" do
      connect()
      pid = remote_pid(@node, 45)

      Pid.put_format(:local)
      local = TermFormatter.copy_string(pid, syntax: :erlang)

      Pid.put_format(:distribution)
      assert TermFormatter.copy_string(pid, syntax: :erlang) == local
    end
  end

  test "displays pids in the PID format setting in the Erlang syntax" do
    connect()
    pid = remote_pid(@node, 45)

    Pid.put_format(:local)
    assert TermFormatter.inspect({pid}, syntax: :erlang) == "{<0.45.0>}"

    Pid.put_format(:distribution)
    assert TermFormatter.inspect({pid}, syntax: :erlang) == "{<#{Pid.cached_node_id()}.45.0>}"
  end
end

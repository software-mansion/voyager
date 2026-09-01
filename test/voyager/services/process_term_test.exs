defmodule Voyager.Services.ProcessTermTest do
  # async: false because the live tests swap the global `:erpc` impl to
  # `Voyager.Erpc.Impl`, which races any other async module doing the same.
  use ExUnit.Case, async: false

  import Mox

  alias Voyager.Services.ProcessTerm

  setup :verify_on_exit!

  # `.erl` sources under priv/ are not built by mix, so compile and load the
  # agent here to exercise the real remote-side truncation against this node.
  setup_all do
    path = :voyager |> :code.priv_dir() |> Path.join("voyager_agent.erl")
    {:ok, module, binary} = :compile.file(String.to_charlist(path), [:binary])
    {:module, ^module} = :code.load_binary(module, String.to_charlist(path), binary)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    :ok
  end

  describe "against live local processes" do
    setup do
      prev_erpc = Application.get_env(:voyager, :erpc)
      Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
      on_exit(fn -> Application.put_env(:voyager, :erpc, prev_erpc) end)
      :ok
    end

    test "fetch_state/4 returns the state of an OTP-behaviour process" do
      state = %{count: 1, items: [:a, :b]}
      pid = start_supervised!({Agent, fn -> state end})

      assert {:ok, %{term: ^state, truncated?: false}} = ProcessTerm.fetch_state(Node.self(), pid)
    end

    test "fetch_state/4 truncates a state over the budget" do
      pid = start_supervised!({Agent, fn -> Enum.to_list(1..1_000) end})

      assert {:ok, %{term: term, truncated?: true}} =
               ProcessTerm.fetch_state(Node.self(), pid, 20)

      assert List.last(term) == :"$voyager_truncated"
      assert length(term) < 1_000
    end

    # A raw process never answers the system message, and neither does a busy
    # OTP process, so both surface the same way.
    test "fetch_state/4 times out for a process that handles no system messages" do
      pid = spawn_idle()
      kill_on_exit([pid])

      assert {:error, :timeout} == ProcessTerm.fetch_state(Node.self(), pid, 1_000, 50)
    end

    test "fetch_state/4 returns {:error, :dead} for a dead pid" do
      assert {:error, :dead} == ProcessTerm.fetch_state(Node.self(), dead_pid())
    end

    test "fetch_messages/5 caps the mailbox while reporting the real total" do
      pid = spawn_idle()
      kill_on_exit([pid])
      Enum.each(1..10, &send(pid, {:msg, &1}))

      assert {:ok, %{total: 10, truncated?: true, items: items}} =
               ProcessTerm.fetch_messages(Node.self(), pid, 3)

      assert items == [{:msg, 1}, {:msg, 2}, {:msg, 3}]
    end

    test "fetch_messages/5 truncates an oversized message on the remote" do
      pid = spawn_idle()
      kill_on_exit([pid])
      send(pid, {:big, Enum.to_list(1..1_000)})

      assert {:ok, %{total: 1, truncated?: true, items: [{:big, value}]}} =
               ProcessTerm.fetch_messages(Node.self(), pid, 10, 20)

      assert List.last(value) == :"$voyager_truncated"
    end

    test "fetch_messages/5 returns an empty mailbox untruncated" do
      pid = spawn_idle()
      kill_on_exit([pid])

      assert {:ok, %{total: 0, truncated?: false, items: []}} ==
               ProcessTerm.fetch_messages(Node.self(), pid, 10)
    end

    test "fetch_messages/5 returns {:error, :dead} for a dead pid" do
      assert {:error, :dead} == ProcessTerm.fetch_messages(Node.self(), dead_pid(), 10)
    end
  end

  describe "with non-pid input" do
    test "return {:error, :not_a_pid}" do
      assert {:error, :not_a_pid} == ProcessTerm.fetch_state(:demo@localhost, nil)
      assert {:error, :not_a_pid} == ProcessTerm.fetch_messages(:demo@localhost, nil, 10)
    end
  end

  describe "error translation" do
    test "surfaces a missing agent as a remote :undef exception" do
      expect(Voyager.ErpcMock, :call, fn _node, :voyager_agent, :proc_state, _args, _timeout ->
        :erlang.error({:exception, :undef, []})
      end)

      assert {:error, {:remote_exception, :undef}} ==
               ProcessTerm.fetch_state(:demo@localhost, self())
    end

    test "surfaces a transport timeout" do
      expect(Voyager.ErpcMock, :call, fn _node, :voyager_agent, :proc_messages, _args, _timeout ->
        :erlang.error({:erpc, :timeout})
      end)

      assert {:error, :timeout} == ProcessTerm.fetch_messages(:demo@localhost, self(), 10)
    end

    test "surfaces a lost connection" do
      expect(Voyager.ErpcMock, :call, fn _node, :voyager_agent, :proc_state, _args, _timeout ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert {:error, :noconnection} == ProcessTerm.fetch_state(:demo@localhost, self())
    end

    # The remote's own timeout has to fire first, or a slow process reads as an
    # opaque transport failure instead of {:error, :timeout}.
    test "gives the remote sys timeout room under the erpc timeout" do
      expect(Voyager.ErpcMock, :call, fn _node,
                                         :voyager_agent,
                                         :proc_state,
                                         [_pid, _budget, remote_timeout],
                                         erpc_timeout ->
        assert remote_timeout < erpc_timeout
        {:ok, %{term: :ok, truncated: false}}
      end)

      assert {:ok, %{term: :ok, truncated?: false}} ==
               ProcessTerm.fetch_state(:demo@localhost, self(), 100, 500)
    end
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end

  defp spawn_idle do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, :ready)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :ready
    pid
  end

  defp kill_on_exit(pids) do
    on_exit(fn -> Enum.each(pids, &Process.exit(&1, :kill)) end)
  end
end

defmodule Voyager.Services.ProcessTermTest do
  # async: false because other modules swap the global `:erpc` impl to
  # `Voyager.Erpc.Impl`, which would restore it underneath this module's mock.
  use ExUnit.Case, async: false

  import Mox

  alias Voyager.Services.ProcessTerm

  setup :verify_on_exit!

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
end

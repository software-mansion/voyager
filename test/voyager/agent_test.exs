defmodule Voyager.AgentTest do
  use ExUnit.Case, async: true

  import Mox

  alias Voyager.Agent

  # test_helper points the global :erpc impl at Voyager.ErpcMock, so every call
  # here is served by expectations set in the test process.
  setup :verify_on_exit!

  @node :"peer@127.0.0.1"

  describe "call/4" do
    test "returns {:ok, result} and targets the :voyager_agent module" do
      expect(Voyager.ErpcMock, :call, fn node, mod, fun, args, timeout ->
        assert node == @node
        assert mod == :voyager_agent
        assert fun == :proc_top
        assert args == [[:memory], :memory, 10]
        assert timeout == 5_000
        [%{pid: self(), memory: 1}]
      end)

      assert {:ok, [%{memory: 1}]} =
               Agent.call(@node, :proc_top, [[:memory], :memory, 10], 5_000)
    end

    test "translates an :erpc timeout" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ -> :erlang.error({:erpc, :timeout}) end)

      assert {:error, :timeout} = Agent.call(@node, :proc_top, [], 1)
    end

    test "translates an :erpc noconnection" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert {:error, :noconnection} = Agent.call(@node, :proc_top, [], 1_000)
    end

    test "translates a remote exception, dropping the stack" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:exception, %RuntimeError{message: "boom"}, [:some_stack]})
      end)

      assert {:error, {:remote_exception, %RuntimeError{message: "boom"}}} =
               Agent.call(@node, :proc_top, [], 1_000)
    end

    test "passes through other :erpc errors unchanged" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, {:badnode, :nope}})
      end)

      assert {:error, {:erpc, {:badnode, :nope}}} = Agent.call(@node, :proc_top, [], 1_000)
    end

    test "translates a non-:erpc error raised in transport" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ -> :erlang.error(:boom) end)

      assert {:error, :boom} = Agent.call(@node, :proc_top, [], 1_000)
    end

    test "translates a remote exit" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ -> exit(:down) end)

      assert {:error, {:remote_exit, :down}} = Agent.call(@node, :proc_top, [], 1_000)
    end

    test "translates a remote throw" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ -> throw(:nope) end)

      assert {:error, {:remote_throw, :nope}} = Agent.call(@node, :proc_top, [], 1_000)
    end
  end
end

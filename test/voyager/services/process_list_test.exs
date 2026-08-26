defmodule Voyager.Services.ProcessListTest do
  use ExUnit.Case, async: true

  import Mox

  alias Voyager.Services.ProcessList

  setup :verify_on_exit!

  @node :"peer@127.0.0.1"

  # Captures the args reaching the (mocked) :erpc transport and returns an empty
  # process list so `top/5` yields `{:ok, []}`.
  defp capture_erpc_args do
    test = self()

    expect(Voyager.ErpcMock, :call, fn node, mod, fun, args, timeout ->
      send(test, {:called, node, mod, fun, args, timeout})
      []
    end)
  end

  describe "top/5" do
    test "invokes :voyager_agent.proc_top on the given node with node, args and timeout" do
      capture_erpc_args()

      assert {:ok, []} = ProcessList.top(@node, [:memory, :reductions], :memory, 25, 3_000)

      assert_received {:called, @node, :voyager_agent, :proc_top,
                       [[:memory, :reductions], :memory, 25, :desc], 3_000}
    end

    test "defaults the sort direction to :desc" do
      capture_erpc_args()

      assert {:ok, []} = ProcessList.top(@node, [:memory], :memory, 5, 1_000)

      assert_received {:called, _node, _mod, _fun, [_attrs, :memory, 5, :desc], _timeout}
    end

    test "passes an explicit :asc direction through to the agent" do
      capture_erpc_args()

      assert {:ok, []} = ProcessList.top(@node, [:memory], :memory, 5, 1_000, :asc)

      assert_received {:called, _node, _mod, _fun, [_attrs, :memory, 5, :asc], _timeout}
    end

    test "rejects an unknown direction" do
      assert_raise FunctionClauseError, fn ->
        ProcessList.top(@node, [:memory], :memory, 5, 1_000, :sideways)
      end
    end

    test "adds sort_by to the fetched attributes when missing" do
      capture_erpc_args()

      assert {:ok, []} = ProcessList.top(@node, [:reductions], :memory, 5, 1_000)

      assert_received {:called, _node, _mod, _fun, [[:memory, :reductions], :memory, 5, :desc],
                       _timeout}
    end

    test "does not duplicate sort_by when it is already among the attributes" do
      capture_erpc_args()

      assert {:ok, []} = ProcessList.top(@node, [:memory, :reductions], :memory, 5, 1_000)

      assert_received {:called, _node, _mod, _fun, [[:memory, :reductions], :memory, 5, :desc],
                       _timeout}
    end

    test "returns the entries produced by the agent" do
      rows = [%{pid: self(), memory: 10}]
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ -> rows end)

      assert {:ok, ^rows} = ProcessList.top(@node, [:memory], :memory, 5, 1_000)
    end

    test "propagates transport errors from the agent seam" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert {:error, :noconnection} = ProcessList.top(@node, [:memory], :memory, 5, 1_000)
    end
  end
end

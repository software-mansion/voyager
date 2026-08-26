defmodule Voyager.Services.ProcessListTest do
  use ExUnit.Case, async: true

  import Mox

  alias Voyager.Services.ProcessList

  setup :verify_on_exit!

  @node :"peer@127.0.0.1"

  # Captures the args reaching the (mocked) :erpc transport and returns an empty
  # top-N with a total count, so `top/7` yields `{:ok, {[], 0}}`.
  defp capture_erpc_args do
    test = self()

    expect(Voyager.ErpcMock, :call, fn node, mod, fun, args, timeout ->
      send(test, {:called, node, mod, fun, args, timeout})
      {[], 0}
    end)
  end

  describe "top/7" do
    test "invokes :voyager_agent.proc_top on the given node with node, args and timeout" do
      capture_erpc_args()

      assert {:ok, {[], _}} = ProcessList.top(@node, [:memory, :reductions], :memory, 25, 3_000)

      assert_received {:called, @node, :voyager_agent, :proc_top,
                       [[:memory, :reductions], :memory, 25, :desc, :undefined], 3_000}
    end

    test "defaults the sort direction to :desc" do
      capture_erpc_args()

      assert {:ok, {[], _}} = ProcessList.top(@node, [:memory], :memory, 5, 1_000)

      assert_received {:called, _node, _mod, _fun, [_attrs, :memory, 5, :desc, :undefined],
                       _timeout}
    end

    test "passes an explicit :asc direction through to the agent" do
      capture_erpc_args()

      assert {:ok, {[], _}} = ProcessList.top(@node, [:memory], :memory, 5, 1_000, :asc)

      assert_received {:called, _node, _mod, _fun, [_attrs, :memory, 5, :asc, :undefined],
                       _timeout}
    end

    test "defaults the search to :undefined (no filter)" do
      capture_erpc_args()

      assert {:ok, {[], _}} = ProcessList.top(@node, [:memory], :memory, 5, 1_000)

      assert_received {:called, _node, _mod, _fun, [_attrs, :memory, 5, :desc, :undefined],
                       _timeout}
    end

    test "normalizes a blank search string to :undefined" do
      capture_erpc_args()

      assert {:ok, {[], _}} = ProcessList.top(@node, [:memory], :memory, 5, 1_000, :desc, "")

      assert_received {:called, _node, _mod, _fun, [_attrs, :memory, 5, :desc, :undefined],
                       _timeout}
    end

    test "passes a non-blank search string through to the agent" do
      capture_erpc_args()

      assert {:ok, {[], _}} =
               ProcessList.top(
                 @node,
                 [:memory, :registered_name],
                 :memory,
                 5,
                 1_000,
                 :desc,
                 "gen"
               )

      assert_received {:called, _node, _mod, _fun,
                       [[:memory, :registered_name], :memory, 5, :desc, "gen"], _timeout}
    end

    test "rejects an unknown direction" do
      assert_raise FunctionClauseError, fn ->
        ProcessList.top(@node, [:memory], :memory, 5, 1_000, :sideways)
      end
    end

    test "adds sort_by to the fetched attributes when missing" do
      capture_erpc_args()

      assert {:ok, {[], _}} = ProcessList.top(@node, [:reductions], :memory, 5, 1_000)

      assert_received {:called, _node, _mod, _fun,
                       [[:memory, :reductions], :memory, 5, :desc, :undefined], _timeout}
    end

    test "does not duplicate sort_by when it is already among the attributes" do
      capture_erpc_args()

      assert {:ok, {[], _}} = ProcessList.top(@node, [:memory, :reductions], :memory, 5, 1_000)

      assert_received {:called, _node, _mod, _fun,
                       [[:memory, :reductions], :memory, 5, :desc, :undefined], _timeout}
    end

    test "returns the entries and total count produced by the agent" do
      rows = [%{pid: self(), memory: 10}]
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ -> {rows, 42} end)

      assert {:ok, {^rows, 42}} = ProcessList.top(@node, [:memory], :memory, 5, 1_000)
    end

    test "rejects a disallowed attribute without touching the remote" do
      assert {:error, {:unsupported_attrs, [:messages]}} =
               ProcessList.top(@node, [:memory, :messages], :memory, 5, 1_000)
    end

    test "rejects a disallowed sort_by without touching the remote" do
      assert {:error, {:unsupported_attrs, [:dictionary]}} =
               ProcessList.top(@node, [:memory], :dictionary, 5, 1_000)
    end

    test "rejects a display-only attribute as sort_by without touching the remote" do
      assert {:error, {:unsupported_sort_by, :registered_name}} =
               ProcessList.top(@node, [:memory], :registered_name, 5, 1_000)
    end

    test "propagates transport errors from the agent seam" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert {:error, :noconnection} = ProcessList.top(@node, [:memory], :memory, 5, 1_000)
    end
  end
end

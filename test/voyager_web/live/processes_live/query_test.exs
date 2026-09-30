defmodule VoyagerWeb.ProcessesLive.QueryTest do
  # async: false: the LiveView tests drive the same Voyager.ErpcMock in Mox
  # global mode, where their stubs would override this test's expectations.
  use ExUnit.Case, async: false

  import Mox
  import Voyager.Fakes, only: [capture_erpc_args: 0]

  alias VoyagerWeb.FormSchemas.ProcessListControls
  alias VoyagerWeb.ProcessesLive.Query

  setup :verify_on_exit!

  @agent_module Voyager.Agent.module()

  @node :"peer@127.0.0.1"

  defp controls(attrs \\ %{}) do
    {controls, _changeset} = ProcessListControls.apply(ProcessListControls.default(), attrs)
    controls
  end

  describe "page/3" do
    test "requests the selected attributes with the form's defaults" do
      capture_erpc_args()

      assert {:ok, _page} = Query.page(@node, controls())

      assert_received {:called, @node, @agent_module, :proc_top,
                       [attrs, :memory, 100, :desc, :undefined], 5_000}

      expected = ProcessListControls.default() |> ProcessListControls.attrs() |> List.delete(:pid)
      assert Enum.sort(attrs) == Enum.sort(expected)
    end

    test "passes the form's limit, timeout and search through to the remote" do
      capture_erpc_args()

      assert {:ok, _page} =
               Query.page(
                 @node,
                 controls(%{"limit" => 25, "timeout" => 3_000, "search" => "gen"})
               )

      assert_received {:called, _node, _mod, _fun, [_attrs, _sort, 25, _dir, "gen"], 3_000}
    end

    test "passes the sort through, separately from the form" do
      capture_erpc_args()

      assert {:ok, _page} = Query.page(@node, controls(), {:reductions, :asc})

      assert_received {:called, _node, _mod, _fun, [_attrs, :reductions, _limit, :asc, _search],
                       _timeout}
    end

    test "requests only the selected columns, plus the required ones" do
      capture_erpc_args()

      assert {:ok, _page} = Query.page(@node, controls(%{"columns" => ["status"]}))

      # :pid is implicit on every entry, so it is never requested.
      assert_received {:called, _node, _mod, _fun, [attrs, _sort, _limit, _dir, _search],
                       _timeout}

      assert Enum.sort(attrs) == [:memory, :status]
    end

    test "normalizes a blank search to no filter" do
      capture_erpc_args()

      assert {:ok, _page} = Query.page(@node, controls(%{"search" => "   "}))

      assert_received {:called, _node, _mod, _fun, [_attrs, _sort, _limit, _dir, :undefined],
                       _timeout}
    end

    test "propagates transport errors" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert {:error, :noconnection} = Query.page(@node, controls())
    end
  end
end

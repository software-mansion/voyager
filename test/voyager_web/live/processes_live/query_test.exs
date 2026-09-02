defmodule VoyagerWeb.ProcessesLive.QueryTest do
  # async: false: the LiveView tests drive the same Voyager.ErpcMock in Mox
  # global mode, where their stubs would override this test's expectations.
  use ExUnit.Case, async: false

  import Mox

  alias VoyagerWeb.FormSchemas.ProcessListControls
  alias VoyagerWeb.ProcessesLive.Query

  setup :verify_on_exit!

  @node :"peer@127.0.0.1"

  # Captures the args reaching the (mocked) :erpc transport and returns an empty
  # top-N, so `page/2` yields an empty page.
  defp capture_erpc_args(result \\ {[], 0}) do
    test = self()

    expect(Voyager.ErpcMock, :call, fn node, mod, fun, args, timeout ->
      send(test, {:called, node, mod, fun, args, timeout})
      result
    end)
  end

  defp controls(attrs \\ %{}) do
    {controls, _changeset} = ProcessListControls.apply(ProcessListControls.default(), attrs)
    controls
  end

  describe "page/3" do
    test "requests the selected attributes with the form's defaults" do
      capture_erpc_args()

      assert {:ok, _page} = Query.page(@node, controls())

      assert_received {:called, @node, :voyager_agent, :proc_top,
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

    test "returns entries with scan metadata" do
      rows = [%{pid: self(), memory: 10}]
      capture_erpc_args({rows, 42})

      assert {:ok, page} = Query.page(@node, controls())

      assert page.entries == rows
      assert page.scanned == 42
      assert %DateTime{} = page.fetched_at
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

  describe "attribute metadata" do
    test "every sortable attribute is selectable or required" do
      known = Query.required_attrs() ++ Query.optional_attrs()
      assert Enum.all?(Query.sortable_attrs(), &(&1 in known))
    end

    test "clamp_attrs/1 always includes the required attributes" do
      for required <- Query.required_attrs() do
        assert required in Query.clamp_attrs([])
        assert required in Query.clamp_attrs([:status])
      end
    end

    test "clamp_attrs/1 drops unknown attributes" do
      refute :messages in Query.clamp_attrs([:messages, :status])
      assert :status in Query.clamp_attrs([:messages, :status])
    end
  end
end

defmodule Voyager.Queries.ProcessesTest do
  use ExUnit.Case, async: true

  import Mox

  alias Voyager.Queries.Processes

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

  describe "page/2" do
    test "requests the fixed attribute set with the defaults" do
      capture_erpc_args()

      assert {:ok, _page} = Processes.page(@node)

      assert_received {:called, @node, :voyager_agent, :proc_top,
                       [attrs, :memory, 100, :desc, :undefined], 5_000}

      assert Enum.sort(attrs) == Enum.sort(Processes.attrs())
    end

    test "passes sort_by, direction, limit and search through to the remote" do
      capture_erpc_args()

      assert {:ok, _page} =
               Processes.page(@node,
                 sort_by: :reductions,
                 direction: :asc,
                 limit: 25,
                 search: "gen"
               )

      assert_received {:called, _node, _mod, _fun, [_attrs, :reductions, 25, :asc, "gen"],
                       _timeout}
    end

    test "returns entries with scan metadata" do
      rows = [%{pid: self(), memory: 10}]
      capture_erpc_args({rows, 42})

      assert {:ok, page} = Processes.page(@node, limit: 25)

      assert page.entries == rows
      assert page.scanned == 42
      assert page.truncated?
      assert %DateTime{} = page.fetched_at
    end

    test "is not truncated when every scanned process was returned" do
      rows = [%{pid: self(), memory: 10}]
      capture_erpc_args({rows, 1})

      assert {:ok, %{truncated?: false}} = Processes.page(@node)
    end

    test "falls back to the defaults for unknown options" do
      capture_erpc_args()

      assert {:ok, _page} =
               Processes.page(@node,
                 sort_by: :registered_name,
                 direction: :sideways,
                 limit: 7
               )

      assert_received {:called, _node, _mod, _fun, [_attrs, :memory, 100, :desc, :undefined],
                       _timeout}
    end

    test "clamps the timeout into the supported bounds" do
      {min, max} = Processes.timeout_bounds()

      capture_erpc_args()
      assert {:ok, _page} = Processes.page(@node, timeout: 1)
      assert_received {:called, _node, _mod, _fun, _args, ^min}

      capture_erpc_args()
      assert {:ok, _page} = Processes.page(@node, timeout: 10_000_000)
      assert_received {:called, _node, _mod, _fun, _args, ^max}
    end

    test "normalizes a blank or whitespace-only search to no filter" do
      capture_erpc_args()
      assert {:ok, _page} = Processes.page(@node, search: "   ")

      assert_received {:called, _node, _mod, _fun, [_attrs, _sort, _limit, _dir, :undefined],
                       _timeout}
    end

    test "trims a padded search term" do
      capture_erpc_args()
      assert {:ok, _page} = Processes.page(@node, search: "  gen  ")

      assert_received {:called, _node, _mod, _fun, [_attrs, _sort, _limit, _dir, "gen"], _timeout}
    end

    test "propagates transport errors" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert {:error, :noconnection} = Processes.page(@node)
    end
  end

  describe "parse_pid/1" do
    test "parses an external pid string" do
      pid_string = Processes.format_pid(self())

      assert {:ok, pid} = Processes.parse_pid(pid_string)
      assert pid == self()
    end

    test "returns :error for malformed input" do
      assert :error = Processes.parse_pid("not-a-pid")
      assert :error = Processes.parse_pid("")
      assert :error = Processes.parse_pid(nil)
    end
  end

  describe "format_pid/1" do
    test "formats a pid in its external form" do
      assert "<" <> _rest = Processes.format_pid(self())
    end
  end

  describe "option metadata" do
    test "every sortable attribute is among the fetched attributes" do
      assert Enum.all?(Processes.sortable_attrs(), &(&1 in Processes.attrs()))
    end

    test "the default limit is selectable" do
      assert Processes.default_limit() in Processes.limit_options()
    end

    test "the default sort_by is sortable" do
      assert Processes.default_sort_by() in Processes.sortable_attrs()
    end

    test "the default timeout is within bounds" do
      {min, max} = Processes.timeout_bounds()
      assert Processes.default_timeout() >= min
      assert Processes.default_timeout() <= max
    end
  end
end

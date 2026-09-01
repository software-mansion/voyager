defmodule Voyager.Queries.ProcessesTest do
  # async: false because the process list / details LiveView tests drive the
  # same Voyager.ErpcMock in Mox global mode, where their stubs would otherwise
  # override this test's expectations.
  use ExUnit.Case, async: false

  import Mox

  alias Voyager.Queries.Processes
  alias VoyagerWeb.FormSchemas.ProcessListControls

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

      assert {:ok, _page} = Processes.page(@node, controls())

      assert_received {:called, @node, :voyager_agent, :proc_top,
                       [attrs, :memory, 100, :desc, :undefined], 5_000}

      expected = ProcessListControls.default() |> ProcessListControls.attrs() |> List.delete(:pid)
      assert Enum.sort(attrs) == Enum.sort(expected)
    end

    test "passes the form's limit, timeout and search through to the remote" do
      capture_erpc_args()

      assert {:ok, _page} =
               Processes.page(
                 @node,
                 controls(%{"limit" => 25, "timeout" => 3_000, "search" => "gen"})
               )

      assert_received {:called, _node, _mod, _fun, [_attrs, _sort, 25, _dir, "gen"], 3_000}
    end

    test "passes the sort through, separately from the form" do
      capture_erpc_args()

      assert {:ok, _page} = Processes.page(@node, controls(), {:reductions, :asc})

      assert_received {:called, _node, _mod, _fun, [_attrs, :reductions, _limit, :asc, _search],
                       _timeout}
    end

    test "returns entries with scan metadata" do
      rows = [%{pid: self(), memory: 10}]
      capture_erpc_args({rows, 42})

      assert {:ok, page} = Processes.page(@node, controls())

      assert page.entries == rows
      assert page.scanned == 42
      assert %DateTime{} = page.fetched_at
    end

    test "requests only the selected columns, plus the required ones" do
      capture_erpc_args()

      assert {:ok, _page} = Processes.page(@node, controls(%{"columns" => ["status"]}))

      # :pid is implicit on every entry, so it is never requested.
      assert_received {:called, _node, _mod, _fun, [attrs, _sort, _limit, _dir, _search],
                       _timeout}

      assert Enum.sort(attrs) == [:memory, :status]
    end

    test "normalizes a blank search to no filter" do
      capture_erpc_args()

      assert {:ok, _page} = Processes.page(@node, controls(%{"search" => "   "}))

      assert_received {:called, _node, _mod, _fun, [_attrs, _sort, _limit, _dir, :undefined],
                       _timeout}
    end

    test "propagates transport errors" do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ ->
        :erlang.error({:erpc, :noconnection})
      end)

      assert {:error, :noconnection} = Processes.page(@node, controls())
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

  describe "attribute metadata" do
    test "every sortable attribute is selectable or required" do
      known = Processes.required_attrs() ++ Processes.optional_attrs()
      assert Enum.all?(Processes.sortable_attrs(), &(&1 in known))
    end

    test "clamp_attrs/1 always includes the required attributes" do
      for required <- Processes.required_attrs() do
        assert required in Processes.clamp_attrs([])
        assert required in Processes.clamp_attrs([:status])
      end
    end

    test "clamp_attrs/1 drops unknown attributes" do
      refute :messages in Processes.clamp_attrs([:messages, :status])
      assert :status in Processes.clamp_attrs([:messages, :status])
    end
  end
end

defmodule Voyager.MCP.Tools.ProcessListTest do
  # async: false because the tool reads the global `Voyager.NodeSession`.
  use ExUnit.Case, async: false

  import Mox

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.ProcessList

  setup :verify_on_exit!

  setup do
    node = :fake@localhost
    Fakes.connect_node!(Fakes.node_session(node: node, node_name: Atom.to_string(node)))

    %{data: Fakes.process_data()}
  end

  describe "schema validation" do
    test "rejects an unrankable sort_by" do
      assert {:error, _errors} = ProcessList.mcp_schema(%{"sort_by" => "registered_name"})
    end

    test "rejects a limit past the maximum" do
      assert {:error, _errors} = ProcessList.mcp_schema(%{"limit" => 101})
    end

    test "rejects an attribute outside the allowed set" do
      assert {:error, _errors} = ProcessList.mcp_schema(%{"attrs" => ["messages"]})
    end

    test "defaults the limit, ranking and columns" do
      assert {:ok, params} = ProcessList.mcp_schema(%{})

      assert params.limit == 25
      assert params.sort_by == "memory"
      assert params.direction == "desc"
      assert params.attrs == ~w(memory reductions message_queue_len registered_name)
    end
  end

  describe "execute/2" do
    test "renders the ranked rows and the scan total", %{data: data} do
      Fakes.stub_erpc(data)

      assert run(%{"limit" => 3}) == %{
               "total_scanned" => 42,
               "processes" => [
                 %{
                   "pid" => "<0.301.0>",
                   "memory" => 9_000,
                   "reductions" => 300,
                   "registered_name" => "big"
                 },
                 %{
                   "pid" => "<0.302.0>",
                   "memory" => 5_000,
                   "reductions" => 200,
                   "registered_name" => []
                 },
                 %{
                   "pid" => "<0.303.0>",
                   "memory" => 1_000,
                   "reductions" => 100,
                   "registered_name" => "small"
                 }
               ]
             }
    end

    test "sends the requested ranking to the remote", %{data: data} do
      assert [_attrs, :reductions, 7, :asc, _search] =
               proc_top_args(data, %{
                 "limit" => 7,
                 "sort_by" => "reductions",
                 "direction" => "asc"
               })
    end

    test "sends the requested columns, with sort_by added", %{data: data} do
      assert [attrs, :reductions, _limit, _direction, _search] =
               proc_top_args(data, %{"sort_by" => "reductions", "attrs" => ["registered_name"]})

      assert attrs == [:reductions, :registered_name]
    end

    test "deduplicates the requested columns", %{data: data} do
      assert [[:memory], :memory, _limit, _direction, _search] =
               proc_top_args(data, %{"attrs" => ["memory", "memory"]})
    end

    test "sends the search filter to the remote", %{data: data} do
      assert [_attrs, _sort_by, _limit, _direction, "worker"] =
               proc_top_args(data, %{"search" => "worker"})
    end

    test "sends no filter when the search is omitted", %{data: data} do
      assert [_attrs, _sort_by, _limit, _direction, :undefined] = proc_top_args(data, %{})
    end
  end

  defp run(params) do
    {:ok, validated} = ProcessList.mcp_schema(params)

    assert {:reply, %Response{isError: false, content: [%{"text" => json}]}, %Frame{}} =
             ProcessList.execute(validated, %Frame{})

    JSON.decode!(json)
  end

  defp proc_top_args(data, params) do
    test = self()

    expect(Voyager.ErpcMock, :call, fn _node, :voyager_agent, :proc_top, args, _timeout ->
      send(test, {:proc_top, args})
      data.proc_top
    end)

    run(params)

    assert_received {:proc_top, args}
    args
  end
end

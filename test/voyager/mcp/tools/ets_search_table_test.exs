defmodule Voyager.MCP.Tools.EtsSearchTableTest do
  use ExUnit.Case, async: false

  import Mox

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.EtsSearchTable

  setup :verify_on_exit!

  setup do
    node = :fake@localhost
    Fakes.connect_node!(Fakes.node_session(node: node, node_name: Atom.to_string(node)))
    :ok
  end

  describe "schema validation" do
    test "requires table and match_spec" do
      assert {:error, _} = EtsSearchTable.mcp_schema(%{})
      assert {:error, _} = EtsSearchTable.mcp_schema(%{"table" => "t"})
      assert {:error, _} = EtsSearchTable.mcp_schema(%{"match_spec" => "[{'$1', [], ['$1']}]"})
    end

    test "accepts table and match_spec" do
      assert {:ok, %{table: "t", match_spec: "[{'$1', [], ['$1']}]", limit: 25}} =
               EtsSearchTable.mcp_schema(%{
                 "table" => "t",
                 "match_spec" => "[{'$1', [], ['$1']}]"
               })
    end
  end

  describe "match spec search" do
    test "returns records matching the spec" do
      stub_select([{:alice, 30}])

      result = run(%{"table" => "code", "match_spec" => "[{'$1', [], ['$_']}]"})

      assert result["records"] == [["alice", 30]]
      assert result["truncated?"] == false
      assert result["cursor"] == nil
    end

    test "returns a cursor for paged results" do
      stub_select([{:alice, 30}], :next_page)

      result = run(%{"table" => "code", "match_spec" => "[{'$1', [], ['$_']}]", "limit" => 1})

      assert result["cursor"] != nil
      assert result["records"] == [["alice", 30]]
    end

    test "decodes a cursor for the next page" do
      cont = :page_two
      cursor = Base.url_encode64(:erlang.term_to_binary(cont))

      stub_select_with_cont(cont, [{:bob, 25}], nil)

      result =
        run(%{
          "table" => "code",
          "match_spec" => "[{'$1', [], ['$_']}]",
          "cursor" => cursor
        })

      assert result["records"] == [["bob", 25]]
      assert result["cursor"] == nil
    end
  end

  describe "errors" do
    test "rejects an invalid match spec" do
      assert error(%{"table" => "code", "match_spec" => "os:cmd(\"whoami\")"}) =~
               "Invalid match spec"
    end

    test "rejects a multi-clause match spec" do
      assert error(%{
               "table" => "code",
               "match_spec" => "[{'$1', [], ['$1']}, {'$2', [], ['$2']}]"
             }) =~ "Invalid match spec"
    end

    test "rejects an invalid cursor" do
      assert error(%{
               "table" => "code",
               "match_spec" => "[{'$1', [], ['$_']}]",
               "cursor" => "bad!!!"
             }) == "Invalid cursor format provided"
    end

    test "reports an invalid table name" do
      assert error(%{
               "table" => "non_existent_table_name_xyz_123",
               "match_spec" => "[{'$1', [], ['$_']}]"
             }) =~ ":invalid_table_name"
    end

    test "reports an invalid table ref" do
      assert error(%{
               "table" => "#Ref<bad>",
               "match_spec" => "[{'$1', [], ['$_']}]"
             }) =~ ":invalid_table_ref"
    end
  end

  defp stub_select(records, continuation \\ nil) do
    chunk = %{
      records: records,
      continuation: continuation || :"$end_of_table",
      truncated: false
    }

    expect(Voyager.ErpcMock, :call, fn
      _node, :voyager_agent, :ets_select_spec, _args, _timeout -> {:ok, chunk}
    end)
  end

  defp stub_select_with_cont(expected_cont, records, continuation) do
    chunk = %{
      records: records,
      continuation: continuation || :"$end_of_table",
      truncated: false
    }

    expect(Voyager.ErpcMock, :call, fn
      _node, :voyager_agent, :ets_select_spec, [_table, _spec, _limit, _budget, cont],
      _timeout ->
        assert cont == expected_cont
        {:ok, chunk}
    end)
  end

  defp execute(params) do
    {:ok, validated} = EtsSearchTable.mcp_schema(params)
    EtsSearchTable.execute(validated, %Frame{})
  end

  defp run(params) do
    assert {:reply, %Response{isError: false, content: [%{"text" => json}]}, %Frame{}} =
             execute(params)

    JSON.decode!(json)
  end

  defp error(params) do
    assert {:reply, %Response{isError: true, content: [%{"text" => text}]}, %Frame{}} =
             execute(params)

    text
  end
end

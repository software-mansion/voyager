defmodule Voyager.MCP.Tools.EtsReadTableChunkTest do
  use ExUnit.Case, async: false

  import Mox

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.EtsReadTableChunk

  setup :verify_on_exit!

  setup do
    node = :fake@localhost
    Fakes.connect_node!(Fakes.node_session(node: node, node_name: Atom.to_string(node)))
    :ok
  end

  describe "schema validation" do
    test "requires a table" do
      assert {:error, _} = EtsReadTableChunk.mcp_schema(%{})
    end

    test "accepts table only for an unfiltered scan" do
      assert {:ok, %{table: "my_table", limit: 25, keypos: 1}} =
               EtsReadTableChunk.mcp_schema(%{"table" => "my_table"})
    end

    test "rejects an unknown mode" do
      assert {:error, _} =
               EtsReadTableChunk.mcp_schema(%{"table" => "t", "mode" => "regex"})
    end

    test "accepts key_eq mode with value" do
      assert {:ok, %{mode: "key_eq", value: "42"}} =
               EtsReadTableChunk.mcp_schema(%{
                 "table" => "t",
                 "mode" => "key_eq",
                 "value" => "42"
               })
    end
  end

  describe "unfiltered scan" do
    test "returns records from select_chunk" do
      stub_chunk([{:alice, 30}, {:bob, 25}])

      result = run(%{"table" => "code"})

      assert result["records"] == [["alice", 30], ["bob", 25]]
      assert result["truncated?"] == false
      assert result["cursor"] == nil
    end

    test "returns a cursor for paged results" do
      cont = :some_continuation
      stub_chunk([{:alice, 30}], cont)

      result = run(%{"table" => "code", "limit" => 1})

      assert result["cursor"] != nil
      assert result["records"] == [["alice", 30]]
    end

    test "decodes a cursor for the next page" do
      cont = :page_two_cont
      cursor = Base.url_encode64(:erlang.term_to_binary(cont))

      stub_chunk_with_cont(cont, [{:bob, 25}], nil)

      result = run(%{"table" => "code", "cursor" => cursor})

      assert result["records"] == [["bob", 25]]
      assert result["cursor"] == nil
    end
  end

  describe "filtered scan" do
    test "key_eq returns lookup results" do
      stub_lookup(:alice, [{:alice, 30}])

      result = run(%{"table" => "code", "mode" => "key_eq", "value" => ":alice"})

      assert result["records"] == [["alice", 30]]
      assert result["cursor"] == nil
    end

    test "key_eq with integer value" do
      stub_lookup(42, [{42, "answer"}])

      result = run(%{"table" => "code", "mode" => "key_eq", "value" => "42"})

      assert result["records"] == [[42, "answer"]]
    end

    test "key_prefix returns matching rows" do
      prefix = "prefix_"
      stub_select_spec([{"prefix_1", 100}])

      result = run(%{"table" => "code", "mode" => "key_prefix", "value" => prefix})

      assert result["records"] == [["prefix_1", 100]]
    end

    test "key_prefix with empty string performs unfiltered scan" do
      stub_chunk([{:alice, 30}])

      result = run(%{"table" => "code", "mode" => "key_prefix", "value" => ""})

      assert result["records"] == [["alice", 30]]
    end

    test "element_eq matches by index and scalar value" do
      stub_select_spec([{:alice, "active", 1}])

      result =
        run(%{
          "table" => "code",
          "mode" => "element_eq",
          "index" => 2,
          "value" => "active"
        })

      assert result["records"] == [["alice", "active", 1]]
    end
  end

  describe "errors" do
    test "rejects an invalid cursor" do
      assert error(%{"table" => "code", "cursor" => "not-base64!!!"}) ==
               "Invalid cursor format provided"
    end

    test "reports a missing value for key_eq" do
      assert error(%{"table" => "code", "mode" => "key_eq"}) =~ "value"
    end

    test "reports a missing index for element_eq" do
      assert error(%{"table" => "code", "mode" => "element_eq", "value" => "x"}) =~ "index"
    end

    test "reports an invalid table name" do
      assert error(%{"table" => "non_existent_table_name_xyz_123"}) =~ ":invalid_table_name"
    end

    test "reports an invalid table ref" do
      assert error(%{"table" => "#Ref<bad>"}) =~ ":invalid_table_ref"
    end
  end

  defp stub_chunk(records, continuation \\ nil) do
    chunk = %{
      records: records,
      continuation: continuation || :"$end_of_table",
      truncated: false
    }

    expect(Voyager.ErpcMock, :call, fn
      _node, :voyager_agent, :ets_select_chunk, _args, _timeout -> {:ok, chunk}
    end)
  end

  defp stub_chunk_with_cont(expected_cont, records, continuation) do
    chunk = %{
      records: records,
      continuation: continuation || :"$end_of_table",
      truncated: false
    }

    expect(Voyager.ErpcMock, :call, fn
      _node, :voyager_agent, :ets_select_chunk, [_table, _limit, _budget, cont], _timeout ->
        assert cont == expected_cont
        {:ok, chunk}
    end)
  end

  defp stub_lookup(expected_key, records) do
    chunk = %{records: records, continuation: :"$end_of_table", truncated: false}

    expect(Voyager.ErpcMock, :call, fn
      _node, :voyager_agent, :ets_lookup, [_table, key, _budget], _timeout ->
        assert key == expected_key
        {:ok, chunk}
    end)
  end

  defp stub_select_spec(records, continuation \\ nil) do
    chunk = %{
      records: records,
      continuation: continuation || :"$end_of_table",
      truncated: false
    }

    expect(Voyager.ErpcMock, :call, fn
      _node, :voyager_agent, :ets_select_spec, _args, _timeout -> {:ok, chunk}
    end)
  end

  defp execute(params) do
    {:ok, validated} = EtsReadTableChunk.mcp_schema(params)
    EtsReadTableChunk.execute(validated, %Frame{})
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

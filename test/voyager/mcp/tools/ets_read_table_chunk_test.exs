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
      stub_intern()
      stub_call(:ets_select_chunk, [{:alice, 30}, {:bob, 25}])

      result = run(%{"table" => "code"})

      assert result["records"] == [["alice", 30], ["bob", 25]]
      assert result["truncated?"] == false
      assert result["cursor"] == nil
    end

    test "returns a cursor for paged results" do
      stub_intern()
      stub_call(:ets_select_chunk, [{:alice, 30}], continuation: :some_continuation)

      result = run(%{"table" => "code", "limit" => 1})

      assert result["cursor"] != nil
      assert result["records"] == [["alice", 30]]
    end

    test "resumes from the cursor of a previous page" do
      stub_intern()
      stub_call(:ets_select_chunk, [{:alice, 30}], continuation: :page_two_cont)
      page1 = run(%{"table" => "code"})

      stub_intern()
      stub_call(:ets_select_chunk, [{:bob, 25}], cont: :page_two_cont)
      page2 = run(%{"table" => "code", "cursor" => page1["cursor"]})

      assert page2["records"] == [["bob", 25]]
      assert page2["cursor"] == nil
    end
  end

  describe "filtered scan" do
    test "key_eq resolves the atom value on the target" do
      stub_intern()
      stub_intern()
      stub_call(:ets_lookup, [{:alice, 30}], key: :alice)

      result = run(%{"table" => "code", "mode" => "key_eq", "value" => ":alice"})

      assert result["records"] == [["alice", 30]]
      assert result["cursor"] == nil
    end

    test "key_eq with integer value" do
      stub_intern()
      stub_call(:ets_lookup, [{42, "answer"}], key: 42)

      result = run(%{"table" => "code", "mode" => "key_eq", "value" => "42"})

      assert result["records"] == [[42, "answer"]]
    end

    test "key_prefix returns matching rows" do
      stub_intern()
      stub_call(:ets_select_spec, [{"prefix_1", 100}])

      result = run(%{"table" => "code", "mode" => "key_prefix", "value" => "prefix_"})

      assert result["records"] == [["prefix_1", 100]]
    end

    test "key_prefix with empty string performs unfiltered scan" do
      stub_intern()
      stub_call(:ets_select_chunk, [{:alice, 30}])

      result = run(%{"table" => "code", "mode" => "key_prefix", "value" => ""})

      assert result["records"] == [["alice", 30]]
    end

    test "element_eq matches by index and scalar value" do
      stub_intern()
      stub_call(:ets_select_spec, [{:alice, "active", 1}])

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

    test "rejects a cursor issued for a different query" do
      stub_intern()
      stub_call(:ets_select_chunk, [{:alice, 30}], continuation: :cont)
      page1 = run(%{"table" => "code"})

      assert error(%{
               "table" => "code",
               "mode" => "key_eq",
               "value" => "42",
               "cursor" => page1["cursor"]
             }) == "Cursor does not match the query parameters"
    end

    test "reports a missing value for key_eq" do
      assert error(%{"table" => "code", "mode" => "key_eq"}) =~ "value"
    end

    test "reports a missing index for element_eq" do
      assert error(%{"table" => "code", "mode" => "element_eq", "value" => "x"}) =~ "index"
    end

    test "reports an atom value not interned on the target" do
      stub_intern_missing()

      assert error(%{"table" => "code", "mode" => "key_eq", "value" => ":no_such_atom"}) =~
               ":unknown_atom_value"
    end

    test "reports an invalid table name" do
      stub_intern_missing()

      assert error(%{"table" => "non_existent_table_name_xyz_123"}) =~ ":invalid_table_name"
    end

    test "reports an invalid table ref" do
      assert error(%{"table" => "#Ref<bad>"}) =~ ":invalid_table_ref"
    end
  end

  defp stub_intern do
    expect(Voyager.ErpcMock, :call, fn _node, :erlang, :list_to_existing_atom, [chars], _t ->
      :erlang.list_to_existing_atom(chars)
    end)
  end

  defp stub_intern_missing do
    expect(Voyager.ErpcMock, :call, fn _node, :erlang, :list_to_existing_atom, _args, _t ->
      :erlang.error({:exception, :badarg, []})
    end)
  end

  defp stub_call(fun, records, opts \\ []) do
    chunk = %{
      records: records,
      continuation: Keyword.get(opts, :continuation, :"$end_of_table"),
      truncated: false
    }

    expect(Voyager.ErpcMock, :call, fn _node, :voyager_agent, ^fun, args, _timeout ->
      if cont = opts[:cont], do: assert(List.last(args) == cont)
      if key = opts[:key], do: assert(Enum.at(args, 1) == key)
      {:ok, chunk}
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

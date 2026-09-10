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
      stub_intern()
      stub_select([{:alice, 30}])

      result = run(%{"table" => "code", "match_spec" => "[{'$1', [], ['$_']}]"})

      assert result["records"] == [["alice", 30]]
      assert result["truncated?"] == false
      assert result["cursor"] == nil
    end

    test "returns a cursor for paged results" do
      stub_intern()
      stub_select([{:alice, 30}], continuation: :next_page)

      result = run(%{"table" => "code", "match_spec" => "[{'$1', [], ['$_']}]", "limit" => 1})

      assert result["cursor"] != nil
      assert result["records"] == [["alice", 30]]
    end

    test "resumes from the cursor of a previous page" do
      stub_intern()
      stub_select([{:alice, 30}], continuation: :page_two)
      page1 = run(%{"table" => "code", "match_spec" => "[{'$1', [], ['$_']}]"})

      stub_intern()
      stub_select([{:bob, 25}], cont: :page_two)

      page2 =
        run(%{
          "table" => "code",
          "match_spec" => "[{'$1', [], ['$_']}]",
          "cursor" => page1["cursor"]
        })

      assert page2["records"] == [["bob", 25]]
      assert page2["cursor"] == nil
    end

    test "resumes when the match spec differs only in formatting" do
      stub_intern()
      stub_select([{:alice, 30}], continuation: :page_two)
      page1 = run(%{"table" => "code", "match_spec" => "[{'$1', [], ['$_']}]"})

      stub_intern()
      stub_select([{:bob, 25}], cont: :page_two)

      page2 =
        run(%{
          "table" => "code",
          "match_spec" => "[{'$1', [], ['$_']}].",
          "cursor" => page1["cursor"]
        })

      assert page2["records"] == [["bob", 25]]
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

    test "rejects a cursor issued for a different match spec" do
      stub_intern()
      stub_select([{:alice, 30}], continuation: :cont)
      page1 = run(%{"table" => "code", "match_spec" => "[{'$1', [], ['$_']}]"})

      assert error(%{
               "table" => "code",
               "match_spec" => "[{'$1', [], ['$1']}]",
               "cursor" => page1["cursor"]
             }) == "Cursor does not match the query parameters"
    end

    test "reports an invalid table name" do
      expect(Voyager.ErpcMock, :call, fn _node, :erlang, :list_to_existing_atom, _args, _t ->
        :erlang.error({:exception, :badarg, []})
      end)

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

  defp stub_intern do
    expect(Voyager.ErpcMock, :call, fn _node, :erlang, :list_to_existing_atom, [chars], _t ->
      :erlang.list_to_existing_atom(chars)
    end)
  end

  defp stub_select(records, opts \\ []) do
    chunk = %{
      records: records,
      continuation: Keyword.get(opts, :continuation, :"$end_of_table"),
      truncated: false
    }

    expect(Voyager.ErpcMock, :call, fn _node, :voyager_agent, :ets_select_spec, args, _timeout ->
      if cont = opts[:cont], do: assert(List.last(args) == cont)
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

defmodule Voyager.MCP.Tools.EtsListTest do
  use ExUnit.Case, async: false

  import Mox

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.EtsFakes
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.EtsList

  setup :verify_on_exit!

  setup do
    node = :fake@localhost
    Fakes.connect_node!(Fakes.node_session(node: node, node_name: Atom.to_string(node)))
    :ok
  end

  describe "schema validation" do
    test "applies defaults" do
      assert {:ok, %{limit: 25, sort_by: "memory", direction: "desc"}} = EtsList.mcp_schema(%{})
    end

    test "rejects an unknown sort attribute" do
      assert {:error, _} = EtsList.mcp_schema(%{"sort_by" => "owner"})
    end
  end

  describe "listing" do
    test "ranks by memory descending by default" do
      EtsFakes.stub_list([
        EtsFakes.table(name: :small, memory: 8),
        EtsFakes.table(name: :big, memory: 800),
        EtsFakes.table(name: :medium, memory: 80)
      ])

      result = run(%{})

      assert names(result) == ["big", "medium", "small"]
      assert result["total"] == 3
    end

    test "sorts by name ascending" do
      EtsFakes.stub_list([
        EtsFakes.table(name: :bravo),
        EtsFakes.table(name: :alpha)
      ])

      result = run(%{"sort_by" => "name", "direction" => "asc"})

      assert names(result) == ["alpha", "bravo"]
    end

    test "takes limit after sorting and reports total before it" do
      EtsFakes.stub_list([
        EtsFakes.table(name: :small, size: 1),
        EtsFakes.table(name: :big, size: 100)
      ])

      result = run(%{"sort_by" => "size", "limit" => 1})

      assert names(result) == ["big"]
      assert result["total"] == 2
    end

    test "filters case-insensitively on the name, total stays unfiltered" do
      EtsFakes.stub_list([
        EtsFakes.table(name: :my_cache),
        EtsFakes.table(name: :other)
      ])

      result = run(%{"search" => "CACHE"})

      assert names(result) == ["my_cache"]
      assert result["total"] == 2
    end

    test "filters on the displayed id of an unnamed table" do
      ref = make_ref()

      EtsFakes.stub_list([
        EtsFakes.table(name: :unnamed, id: ref, named_table: false),
        EtsFakes.table(name: :other)
      ])

      result = run(%{"search" => inspect(ref)})

      assert names(result) == ["unnamed"]
    end

    test "reports a remote failure" do
      EtsFakes.stub_error(:timeout)

      assert error(%{}) =~ "fetch failed"
    end
  end

  defp names(result), do: Enum.map(result["tables"], & &1["name"])

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

  defp execute(params) do
    {:ok, validated} = EtsList.mcp_schema(params)
    EtsList.execute(validated, %Frame{})
  end
end

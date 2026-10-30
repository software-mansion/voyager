defmodule Voyager.MCP.Tools.ModuleListTest do
  # async: false because the tool reads the global `Voyager.NodeSession`.
  use ExUnit.Case, async: false

  import Mox

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.ModuleList
  alias Voyager.Services.ModuleCatalog

  @agent_module Voyager.Agent.module()
  @node :fake@localhost
  @modules [{:lists, :hot}, {Voyager.Pid, :ok}, {Date, :ok}, {:trace, :refused}]

  setup :verify_on_exit!

  setup do
    Fakes.connect_node!(Fakes.node_session(node: @node, node_name: Atom.to_string(@node)))
    ModuleCatalog.refresh(@node)
    on_exit(fn -> ModuleCatalog.refresh(@node) end)
    :ok
  end

  defp stub_modules do
    stub(Voyager.ErpcMock, :call, fn @node, @agent_module, :trace_modules, [], _ -> @modules end)
  end

  defp stub_functions(module, functions) do
    stub(Voyager.ErpcMock, :call, fn
      @node, @agent_module, :trace_modules, [], _ -> @modules
      @node, @agent_module, :trace_functions, [^module], _ -> {:ok, functions}
    end)
  end

  describe "schema validation" do
    test "applies defaults" do
      assert {:ok, %{limit: 50, offset: 0}} = ModuleList.mcp_schema(%{})
    end

    test "rejects a negative offset" do
      assert {:error, _} = ModuleList.mcp_schema(%{"offset" => -1})
    end
  end

  describe "searching modules" do
    test "lists traceable modules sorted by name, without refused ones" do
      stub_modules()

      result = run(%{})

      assert result["modules"] == [
               %{"name" => "Elixir.Date", "traceability" => "ok"},
               %{"name" => "Elixir.Voyager.Pid", "traceability" => "ok"},
               %{"name" => "lists", "traceability" => "hot"}
             ]

      assert result["total"] == 3
      assert result["next_offset"] == nil
    end

    test "fuzzy-filters by name" do
      stub_modules()

      assert %{"modules" => [%{"name" => "Elixir.Voyager.Pid"}], "total" => 1} =
               run(%{"search" => "VPID"})
    end

    test "pages with limit and offset" do
      stub_modules()

      assert %{
               "modules" => [%{"name" => "Elixir.Date"}, %{"name" => "Elixir.Voyager.Pid"}],
               "next_offset" => 2
             } = run(%{"limit" => 2})

      assert %{"modules" => [%{"name" => "lists"}], "next_offset" => nil, "total" => 3} =
               run(%{"limit" => 2, "offset" => 2})
    end

    test "reports a remote failure" do
      stub(Voyager.ErpcMock, :call, fn _, _, _, _, _ -> :erlang.error({:erpc, :timeout}) end)

      assert error(%{}) =~ "fetch failed"
    end
  end

  describe "listing functions" do
    test "lists functions with arity and exported flag" do
      stub_functions(Date, [{:utc_today, 0, true}, {:leap_year?, 1, true}, {:helper, 2, false}])

      result = run(%{"module" => "Date"})

      assert result["module"] == "Elixir.Date"
      assert result["traceability"] == "ok"
      assert result["total"] == 3

      assert result["functions"] == [
               %{"name" => "helper", "arity" => 2, "exported" => false},
               %{"name" => "leap_year?", "arity" => 1, "exported" => true},
               %{"name" => "utc_today", "arity" => 0, "exported" => true}
             ]
    end

    for name <- ["Voyager.Pid", "Elixir.Voyager.Pid"] do
      test "resolves an Elixir module given as #{name}" do
        stub_functions(Voyager.Pid, [{:parse, 1, true}])

        assert %{"module" => "Elixir.Voyager.Pid"} = run(%{"module" => unquote(name)})
      end
    end

    for name <- [":lists", "lists"] do
      test "resolves an Erlang module given as #{name}" do
        stub_functions(:lists, [{:map, 2, true}])

        assert %{"module" => "lists", "traceability" => "hot"} =
                 run(%{"module" => unquote(name)})
      end
    end

    test "fuzzy-filters functions by name/arity, closest first" do
      stub(Voyager.ErpcMock, :call, fn
        @node, @agent_module, :trace_modules, [], _ ->
          [{GenServer, :ok} | @modules]

        @node, @agent_module, :trace_functions, [GenServer], _ ->
          {:ok,
           [{:init, 1, true}, {:handle_cast, 2, true}, {:handle_call, 3, true}, {:call, 1, true}]}
      end)

      assert %{
               "functions" => [
                 %{"name" => "call", "arity" => 1},
                 %{"name" => "handle_call", "arity" => 3}
               ],
               "total" => 2,
               "next_offset" => nil
             } = run(%{"module" => "GenServer", "search" => "call"})
    end

    test "pages functions with limit and offset" do
      stub_functions(Date, [{:a, 0, true}, {:b, 0, true}, {:c, 0, true}])

      assert %{"functions" => [%{"name" => "b"}], "next_offset" => 2, "total" => 3} =
               run(%{"module" => "Date", "limit" => 1, "offset" => 1})
    end

    test "rejects a module that is not loaded" do
      stub_modules()

      assert error(%{"module" => "Nope"}) =~ "not_loaded"
    end

    test "rejects a refused module" do
      stub_modules()

      assert error(%{"module" => ":trace"}) =~ "refused"
    end
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

  defp execute(params) do
    {:ok, validated} = ModuleList.mcp_schema(params)
    ModuleList.execute(validated, %Frame{})
  end
end

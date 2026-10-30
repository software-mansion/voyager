defmodule Voyager.Services.ModuleCatalogTest do
  # async: false: the LiveView tests drive the same Voyager.ErpcMock in Mox global mode.
  use ExUnit.Case, async: false

  import Mox

  alias Voyager.NodeSession
  alias Voyager.Services.ModuleCatalog

  @agent_module Voyager.Agent.module()
  @modules [{:lists, :hot}, {Voyager.Pid, :ok}, {Date, :ok}, {:trace, :refused}]

  setup :verify_on_exit!

  setup do
    node = :"catalog#{System.unique_integer([:positive])}@127.0.0.1"
    on_exit(fn -> ModuleCatalog.refresh(node) end)
    %{node: node}
  end

  defp expect_modules(times \\ 1) do
    expect(Voyager.ErpcMock, :call, times, fn _node, @agent_module, :trace_modules, [], _ ->
      @modules
    end)
  end

  describe "modules/2" do
    test "returns every module sorted by display name", %{node: node} do
      expect_modules()

      assert {:ok, entries} = ModuleCatalog.modules(node)

      assert Enum.map(entries, & &1.name) == [
               "Elixir.Date",
               "Elixir.Voyager.Pid",
               "lists",
               "trace"
             ]

      assert %{module: :lists, traceability: :hot} = Enum.at(entries, 2)
    end

    test "fuzzy-filters by name, case-insensitively", %{node: node} do
      expect_modules()

      assert {:ok, [%{module: Voyager.Pid}]} = ModuleCatalog.modules(node, "voyager.p")
      assert {:ok, [%{module: Voyager.Pid}]} = ModuleCatalog.modules(node, "vpid")
      assert {:ok, [%{module: :lists}]} = ModuleCatalog.modules(node, " LIS ")
      assert {:ok, []} = ModuleCatalog.modules(node, "nothing")
      assert {:ok, [_, _, _, _]} = ModuleCatalog.modules(node, "")
    end

    test "ranks closer matches first", %{node: node} do
      expect_modules()

      assert {:ok, [%{module: :trace}, %{module: Date}, %{module: Voyager.Pid}]} =
               ModuleCatalog.modules(node, "ra")

      assert {:ok, [%{module: Date} | _]} = ModuleCatalog.modules(node, "date")
    end

    test "serves repeated lookups from the cache", %{node: node} do
      expect_modules()

      assert {:ok, _} = ModuleCatalog.modules(node)
      assert {:ok, _} = ModuleCatalog.modules(node, "date")
    end

    test "does not cache a failed fetch", %{node: node} do
      expect(Voyager.ErpcMock, :call, fn _, _, _, _, _ -> :erlang.error({:erpc, :timeout}) end)
      expect_modules()

      assert {:error, :timeout} = ModuleCatalog.modules(node)
      assert {:ok, [_, _, _, _]} = ModuleCatalog.modules(node)
    end

    test "refetches after refresh/1", %{node: node} do
      expect_modules(2)

      assert {:ok, _} = ModuleCatalog.modules(node)
      ModuleCatalog.refresh(node)
      assert {:ok, _} = ModuleCatalog.modules(node)
    end

    test "drops a fetch that finishes after refresh/1", %{node: node} do
      expect(Voyager.ErpcMock, :call, fn _, _, :trace_modules, [], _ ->
        ModuleCatalog.refresh(node)
        [{:stale, :ok}]
      end)

      expect_modules()

      assert {:ok, [%{module: :stale}]} = ModuleCatalog.modules(node)
      assert {:ok, [_, _, _, _]} = ModuleCatalog.modules(node)
    end

    test "refetches once the TTL has passed", %{node: node} do
      Application.put_env(:voyager, :module_catalog_ttl_ms, 0)
      on_exit(fn -> Application.delete_env(:voyager, :module_catalog_ttl_ms) end)
      expect_modules(2)

      assert {:ok, _} = ModuleCatalog.modules(node)
      assert {:ok, _} = ModuleCatalog.modules(node)
    end

    test "drops the cache when the node disconnects", %{node: node} do
      expect_modules(2)

      assert {:ok, _} = ModuleCatalog.modules(node)

      Phoenix.PubSub.broadcast(
        Voyager.PubSub,
        NodeSession.topic(),
        {:node_disconnected, node, nil}
      )

      _ = :sys.get_state(ModuleCatalog)
      assert {:ok, _} = ModuleCatalog.modules(node)
    end
  end

  describe "functions/3" do
    test "fuzzy-matches name/arity with the closest first", %{node: node} do
      expect(Voyager.ErpcMock, :call, fn _, _, :trace_functions, [GenServer], _ ->
        {:ok,
         [{:init, 1, true}, {:handle_cast, 2, true}, {:handle_call, 3, true}, {:call, 1, true}]}
      end)

      names = fn {:ok, entries} -> Enum.map(entries, &{&1.name, &1.arity}) end

      assert names.(ModuleCatalog.functions(node, GenServer, "call")) ==
               [call: 1, handle_call: 3]

      assert names.(ModuleCatalog.functions(node, GenServer, "HANDLE_CALL/3")) ==
               [handle_call: 3]

      assert names.(ModuleCatalog.functions(node, GenServer, "hc")) ==
               [handle_call: 3, handle_cast: 2]

      assert names.(ModuleCatalog.functions(node, GenServer, "nothing")) == []
      assert {:ok, [_, _, _, _]} = ModuleCatalog.functions(node, GenServer, " ")
    end
  end

  describe "functions/2" do
    test "returns functions sorted by name and arity, and caches them", %{node: node} do
      expect(Voyager.ErpcMock, :call, fn ^node, @agent_module, :trace_functions, [Date], _ ->
        {:ok,
         [{:utc_today, 1, true}, {:leap_year?, 1, true}, {:utc_today, 0, true}, {:x, 2, false}]}
      end)

      expected = [
        %{name: :leap_year?, arity: 1, exported?: true},
        %{name: :utc_today, arity: 0, exported?: true},
        %{name: :utc_today, arity: 1, exported?: true},
        %{name: :x, arity: 2, exported?: false}
      ]

      assert {:ok, ^expected} = ModuleCatalog.functions(node, Date)
      assert {:ok, ^expected} = ModuleCatalog.functions(node, Date)
    end

    test "returns the agent's error for a module that is not loaded", %{node: node} do
      expect(Voyager.ErpcMock, :call, 2, fn _, _, :trace_functions, [:gone], _ ->
        {:error, :not_loaded}
      end)

      assert {:error, :not_loaded} = ModuleCatalog.functions(node, :gone)
      assert {:error, :not_loaded} = ModuleCatalog.functions(node, :gone)
    end
  end
end

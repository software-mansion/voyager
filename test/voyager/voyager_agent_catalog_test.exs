defmodule VoyagerAgentCatalogTest do
  use ExUnit.Case, async: false

  @compile {:no_warn_undefined, Voyager.Agent.module()}

  alias Voyager.Services.ProcessList
  alias Voyager.Test.VoyagerAgentFixture

  @agent_module Voyager.Agent.module()

  setup do
    VoyagerAgentFixture.load!()
    :ok
  end

  describe "trace_modules/0" do
    test "tags loaded modules with how they can be traced" do
      Code.ensure_loaded!(Date)
      Code.ensure_loaded!(:trace)
      modules = Map.new(@agent_module.trace_modules())

      assert modules[Date] == :ok
      assert modules[:lists] == :hot
      assert modules[:prim_file] == :hot
      assert modules[:trace] == :refused
      assert modules[@agent_module] == :refused
    end

    test "leaves out modules that are not loaded" do
      :code.purge(:xmerl_scan)
      :code.delete(:xmerl_scan)

      refute List.keymember?(@agent_module.trace_modules(), :xmerl_scan, 0)
    end
  end

  describe "trace_functions/1" do
    test "lists exported and local functions without compiler-generated ones" do
      Code.ensure_loaded!(ProcessList)
      assert {:ok, functions} = @agent_module.trace_functions(ProcessList)

      assert {:top, 7, true} in functions
      assert {:normalize_search, 1, false} in functions
      refute Enum.any?(functions, fn {name, _, _} -> String.starts_with?("#{name}", "-") end)
    end

    test "refuses a module that is not loaded without loading it" do
      :code.purge(:xmerl_scan)
      :code.delete(:xmerl_scan)

      assert {:error, :not_loaded} = @agent_module.trace_functions(:xmerl_scan)
      refute :code.is_loaded(:xmerl_scan)
    end
  end
end

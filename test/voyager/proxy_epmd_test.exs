defmodule Voyager.ProxyEpmdTest do
  use ExUnit.Case, async: false

  alias Voyager.ProxyEpmd
  alias Voyager.ProxyEpmd.TunnelRegistry

  @dist_version 6

  setup do
    key = ~c"proxy_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> TunnelRegistry.unregister(key) end)
    {:ok, key: key}
  end

  describe "port_please/2,3 for a registered node" do
    test "returns the tunnelled local port", %{key: key} do
      TunnelRegistry.register(key, 54_321, self())

      assert {:port, 54_321, @dist_version} = ProxyEpmd.port_please(key, ~c"ignored-host")
    end

    test "returns the tunnelled local port with the timeout arity", %{key: key} do
      TunnelRegistry.register(key, 54_321, self())

      assert {:port, 54_321, @dist_version} =
               ProxyEpmd.port_please(key, ~c"ignored-host", 1000)
    end
  end

  describe "address_please/3 for a registered node" do
    test "returns the loopback address", %{key: key} do
      TunnelRegistry.register(key, 54_321, self())

      assert {:ok, {127, 0, 0, 1}} = ProxyEpmd.address_please(key, ~c"ignored-host", :inet)
    end
  end

  describe "fall-through to :erl_epmd for an unregistered node" do
    test "address_please/3 delegates to :erl_epmd", %{key: key} do
      # key is not registered, so resolution must match :erl_epmd exactly
      assert ProxyEpmd.address_please(key, ~c"localhost", :inet) ==
               :erl_epmd.address_please(key, ~c"localhost", :inet)
    end
  end
end

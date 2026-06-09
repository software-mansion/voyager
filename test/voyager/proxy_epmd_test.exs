defmodule Voyager.ProxyEpmdTest do
  use ExUnit.Case, async: false

  alias Voyager.ProxyEpmd

  @table :proxy_epmd

  setup do
    node_key = ~c"voyager_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> :ets.delete(@table, node_key) end)
    {:ok, node_key: node_key}
  end

  describe "port_please/2" do
    test "returns proxy port and dist version on hit", %{node_key: key} do
      :ets.insert(@table, {key, %{port: 41_234, address: {127, 0, 0, 1}, tunnel: self()}})

      assert {:port, 41_234, 6} = ProxyEpmd.port_please(key, ~c"127.0.0.1")
    end

    test "delegates to :erl_epmd on miss", %{node_key: key} do
      :ets.delete(@table, key)

      assert ProxyEpmd.port_please(key, ~c"127.0.0.1") ==
               :erl_epmd.port_please(key, ~c"127.0.0.1")
    end
  end

  describe "port_please/3" do
    test "returns proxy port and dist version on hit", %{node_key: key} do
      :ets.insert(@table, {key, %{port: 41_234, address: {127, 0, 0, 1}, tunnel: self()}})

      assert {:port, 41_234, 6} = ProxyEpmd.port_please(key, ~c"127.0.0.1", 1_000)
    end

    test "delegates to :erl_epmd on miss", %{node_key: key} do
      :ets.delete(@table, key)

      assert ProxyEpmd.port_please(key, ~c"127.0.0.1", 1_000) ==
               :erl_epmd.port_please(key, ~c"127.0.0.1", 1_000)
    end
  end

  describe "address_please/3" do
    test "returns loopback on hit regardless of requested host", %{node_key: key} do
      :ets.insert(@table, {key, %{port: 41_234, address: {127, 0, 0, 1}, tunnel: self()}})

      assert {:ok, {127, 0, 0, 1}} = ProxyEpmd.address_please(key, ~c"any.host", :inet)
    end

    test "delegates to :erl_epmd on miss", %{node_key: key} do
      :ets.delete(@table, key)

      assert ProxyEpmd.address_please(key, ~c"127.0.0.1", :inet) ==
               :erl_epmd.address_please(key, ~c"127.0.0.1", :inet)
    end
  end

  describe "names/1" do
    test "delegates to :erl_epmd" do
      assert ProxyEpmd.names(~c"127.0.0.1") == :erl_epmd.names(~c"127.0.0.1")
    end
  end
end

defmodule Voyager.ProxyEpmd.TunnelRegistryTest do
  use ExUnit.Case, async: false

  alias Voyager.ProxyEpmd.TunnelRegistry

  @table :proxy_epmd

  setup do
    key = ~c"test_#{System.unique_integer([:positive])}"
    on_exit(fn -> TunnelRegistry.unregister(key) end)
    {:ok, key: key}
  end

  describe "register/3" do
    test "inserts the node into the ETS table", %{key: key} do
      :ok = TunnelRegistry.register(key, 12_345, self())

      assert [{^key, %{port: 12_345, address: {127, 0, 0, 1}, tunnel: pid}}] =
               :ets.lookup(@table, key)

      assert pid == self()
    end

    test "overwrites an existing entry for the same key", %{key: key} do
      TunnelRegistry.register(key, 11_111, self())
      TunnelRegistry.register(key, 22_222, self())

      assert [{^key, %{port: 22_222}}] = :ets.lookup(@table, key)
    end

    test "cancels the old monitor when overwriting so the stale tunnel exit is ignored", %{
      key: key
    } do
      dying = spawn(fn -> receive do: (:stop -> :ok) end)
      TunnelRegistry.register(key, 11_111, dying)
      TunnelRegistry.register(key, 22_222, self())

      ref = Process.monitor(dying)
      send(dying, :stop)
      assert_receive {:DOWN, ^ref, :process, ^dying, _}
      _ = :sys.get_state(TunnelRegistry)

      # Entry must still point to the new registration — old monitor was cancelled
      assert [{^key, %{port: 22_222}}] = :ets.lookup(@table, key)
    end
  end

  describe "unregister/1" do
    test "removes the ETS entry", %{key: key} do
      TunnelRegistry.register(key, 12_345, self())
      :ok = TunnelRegistry.unregister(key)

      assert :ets.lookup(@table, key) == []
    end

    test "is a no-op for an unknown key", %{key: key} do
      assert :ok = TunnelRegistry.unregister(key)
    end
  end

  describe "unregister_by_tunnel/1" do
    test "removes the ETS entry matching the given tunnel pid", %{key: key} do
      TunnelRegistry.register(key, 12_345, self())
      :ok = TunnelRegistry.unregister_by_tunnel(self())

      assert :ets.lookup(@table, key) == []
    end

    test "is a no-op when no entry matches the pid" do
      other = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(other, :stop) end)

      assert :ok = TunnelRegistry.unregister_by_tunnel(other)
    end

    test "cancels the monitor so the later tunnel exit does not double-delete", %{key: key} do
      tunnel = spawn(fn -> receive do: (:stop -> :ok) end)
      TunnelRegistry.register(key, 12_345, tunnel)
      :ok = TunnelRegistry.unregister_by_tunnel(tunnel)

      ref = Process.monitor(tunnel)
      send(tunnel, :stop)
      assert_receive {:DOWN, ^ref, :process, ^tunnel, _}
      _ = :sys.get_state(TunnelRegistry)

      assert :ets.lookup(@table, key) == []
    end
  end

  describe "auto-cleanup on tunnel exit" do
    test "removes the ETS entry when the tunnel pid exits normally", %{key: key} do
      tunnel = spawn(fn -> receive do: (:stop -> :ok) end)
      TunnelRegistry.register(key, 12_345, tunnel)

      ref = Process.monitor(tunnel)
      send(tunnel, :stop)
      assert_receive {:DOWN, ^ref, :process, ^tunnel, _}
      _ = :sys.get_state(TunnelRegistry)

      assert :ets.lookup(@table, key) == []
    end

    test "removes the ETS entry when the tunnel pid crashes", %{key: key} do
      tunnel = spawn(fn -> receive do: (:crash -> exit(:boom)) end)
      TunnelRegistry.register(key, 12_345, tunnel)

      ref = Process.monitor(tunnel)
      send(tunnel, :crash)
      assert_receive {:DOWN, ^ref, :process, ^tunnel, :boom}
      _ = :sys.get_state(TunnelRegistry)

      assert :ets.lookup(@table, key) == []
    end

    test "does not affect entries for other nodes when one tunnel exits", %{key: key} do
      other_key = ~c"other_#{System.unique_integer([:positive])}"
      on_exit(fn -> TunnelRegistry.unregister(other_key) end)

      dying = spawn(fn -> receive do: (:stop -> :ok) end)
      TunnelRegistry.register(key, 11_111, dying)
      TunnelRegistry.register(other_key, 22_222, self())

      ref = Process.monitor(dying)
      send(dying, :stop)
      assert_receive {:DOWN, ^ref, :process, ^dying, _}
      _ = :sys.get_state(TunnelRegistry)

      assert :ets.lookup(@table, key) == []
      assert [{^other_key, %{port: 22_222}}] = :ets.lookup(@table, other_key)
    end
  end
end

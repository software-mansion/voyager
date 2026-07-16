defmodule Voyager.NodeSession.Connectors.SshTest do
  use Voyager.DataCase, async: false

  alias Voyager.NodeSession.Connectors.Ssh
  alias Voyager.ProxyEpmd.TunnelRegistry

  @moduletag capture_log: true

  test "name/0 identifies the connector" do
    assert Ssh.name() == :ssh
  end

  test "subscriptions/0 tracks the shared tunnel-registry topic" do
    assert Ssh.subscriptions() == [TunnelRegistry.topic()]
  end

  describe "teardown?/2" do
    test "is true when :tunnel_down names this connection's conn_ref" do
      conn_ref = self()
      assert Ssh.teardown?({:tunnel_down, conn_ref}, %{conn_ref: conn_ref})
    end

    test "is false when :tunnel_down names a different conn_ref" do
      other = spawn(fn -> :ok end)
      refute Ssh.teardown?({:tunnel_down, other}, %{conn_ref: self()})
    end

    test "is false for unrelated messages" do
      refute Ssh.teardown?(:nodedown, %{conn_ref: self()})
    end
  end

  describe "connect/3" do
    test "raises when :ssh_host is missing" do
      assert_raise KeyError, fn ->
        Ssh.connect("node@127.0.0.1", "cookie", ssh_user: "nobody")
      end
    end

    test "raises when :ssh_user is missing" do
      assert_raise KeyError, fn ->
        Ssh.connect("node@127.0.0.1", "cookie", ssh_host: "127.0.0.1")
      end
    end

    test "returns an error, not a crash, when the SSH gateway is unreachable" do
      assert {:error, _reason} =
               Ssh.connect("node@127.0.0.1", "cookie",
                 ssh_user: "nobody",
                 ssh_host: "127.0.0.1",
                 ssh_port: 1
               )
    end
  end
end

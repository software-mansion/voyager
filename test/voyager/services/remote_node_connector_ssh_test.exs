defmodule Voyager.Services.RemoteNodeConnectorSshTest do
  # async: false because connecting starts distribution for the whole VM.
  use Voyager.DataCase, async: false

  alias Voyager.ProxyEpmd.TunnelRegistry
  alias Voyager.Services.RemoteNodeConnector
  alias Voyager.Test.SshServer

  @moduletag :ssh
  @moduletag capture_log: true

  @cookie "ssh_test_cookie"

  setup do
    %{port: ssh_port, daemon: daemon} = SshServer.start!()
    peer_name = "voyager_ssh_peer_#{System.unique_integer([:positive])}"

    # standard_io keeps the peer off distribution, so only Voyager's tunnel can connect to it.
    {:ok, peer, peer_node} =
      :peer.start(%{
        name: String.to_atom(peer_name),
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [
          ~c"-setcookie",
          String.to_charlist(@cookie),
          ~c"-kernel",
          ~c"logger_level",
          ~c"none"
        ]
      })

    on_exit(fn ->
      :peer.stop(peer)
      :net_kernel.stop()
    end)

    %{ssh_port: ssh_port, daemon: daemon, peer_name: peer_name, peer_node: peer_node}
  end

  defp connect(ctx, overrides \\ []) do
    RemoteNodeConnector.connect(
      SshServer.user(),
      "127.0.0.1",
      Keyword.get(overrides, :node_name, Atom.to_string(ctx.peer_node)),
      Keyword.get(overrides, :cookie, @cookie),
      {:password, Keyword.get(overrides, :password, SshServer.password())},
      ssh_port: ctx.ssh_port
    )
  end

  test "connects to the node through the SSH tunnel", ctx do
    assert {:ok, node, conn_ref, local_port} = connect(ctx)
    assert node == ctx.peer_node
    assert :erpc.call(node, :erlang, :node, []) == node

    node_key = String.to_charlist(ctx.peer_name)

    assert [{^node_key, %{port: ^local_port}}] =
             :ets.lookup(TunnelRegistry.table_name(), node_key)

    Node.monitor(node, true)
    assert :ok = RemoteNodeConnector.stop(conn_ref)
    assert_receive {:nodedown, ^node}, 5_000
    assert :ets.lookup(TunnelRegistry.table_name(), node_key) == []
  end

  test "broadcasts tunnel_down when the SSH server goes away", ctx do
    Phoenix.PubSub.subscribe(Voyager.PubSub, TunnelRegistry.topic())
    assert {:ok, _node, conn_ref, _local_port} = connect(ctx)

    :ssh.stop_daemon(ctx.daemon)

    assert_receive {:tunnel_down, ^conn_ref}, 5_000
  end

  test "fails with a wrong SSH password", ctx do
    assert {:error, _reason} = connect(ctx, password: "wrong")
    refute ctx.peer_node in Node.list(:connected)
  end

  test "fails when the node is not registered in the remote epmd", ctx do
    assert {:error, {:node_not_found, "missing", _names}} =
             connect(ctx, node_name: "missing@127.0.0.1")
  end

  test "fails with a wrong cookie and drops the tunnel", ctx do
    assert {:error, :node_connect_failed} = connect(ctx, cookie: "wrong_cookie")

    node_key = String.to_charlist(ctx.peer_name)
    assert :ets.lookup(TunnelRegistry.table_name(), node_key) == []
  end
end

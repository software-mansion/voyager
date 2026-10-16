defmodule Voyager.Services.RemoteNodeConnectorSshTest do
  use Voyager.DataCase,
    async: false,
    parameterize:
      for(
        ssh_host <- ["127.0.0.1", "::1"],
        {node_host, node_listen} <- [
          {"127.0.0.1", :ipv4},
          {"::1", :dual_stack},
          {"::1", :ipv6_only}
        ],
        do: %{ssh_host: ssh_host, node_host: node_host, node_listen: node_listen}
      )

  alias Voyager.ProxyEpmd.TunnelRegistry
  alias Voyager.Services.RemoteNodeConnector
  alias Voyager.Test.SshServer

  @moduletag :ssh
  @moduletag capture_log: true

  @cookie "ssh_test_cookie"

  setup_all ctx do
    if not Voyager.ProxyEpmd.active?() do
      flunk(
        ~s(run with ELIXIR_ERL_OPTIONS="-proto_dist dual_tcp -epmd_module Elixir.Voyager.ProxyEpmd")
      )
    end

    :inet_db.set_tcp_module(Voyager.Test.DualTcp)
    peer_name = "voyager_ssh_peer_#{System.unique_integer([:positive])}"

    {:ok, peer, peer_node} =
      :peer.start(%{
        name: String.to_atom(peer_name),
        host: String.to_charlist(ctx.node_host),
        longnames: true,
        connection: :standard_io,
        args:
          [
            ~c"-setcookie",
            String.to_charlist(@cookie),
            ~c"-kernel",
            ~c"logger_level",
            ~c"none"
          ] ++ listen_args(ctx.node_listen)
      })

    on_exit(fn -> :peer.stop(peer) end)
    %{peer_name: peer_name, peer_node: peer_node}
  end

  setup ctx do
    {:ok, ssh_address} = :inet.parse_address(String.to_charlist(ctx.ssh_host))
    %{port: ssh_port, daemon: daemon} = SshServer.start!(ssh_address)
    on_exit(fn -> :net_kernel.stop() end)
    %{ssh_port: ssh_port, daemon: daemon}
  end

  defp listen_args(:ipv4), do: []
  defp listen_args(:dual_stack), do: [~c"-proto_dist", ~c"inet6_tcp"]

  defp listen_args(:ipv6_only),
    do:
      listen_args(:dual_stack) ++
        [~c"-kernel", ~c"inet_dist_use_interface", ~c"{0,0,0,0,0,0,0,1}"]

  defp connect(ctx, overrides \\ []) do
    RemoteNodeConnector.connect(
      SshServer.user(),
      ctx.ssh_host,
      Keyword.get(overrides, :node_name, Atom.to_string(ctx.peer_node)),
      Keyword.get(overrides, :cookie, @cookie),
      {:password, SshServer.password()},
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

  test "broadcasts tunnel_down when the SSH server stops responding", ctx do
    Application.put_env(:voyager, :ssh_alive, %{interval: 100, count_max: 2})
    on_exit(fn -> Application.delete_env(:voyager, :ssh_alive) end)
    Phoenix.PubSub.subscribe(Voyager.PubSub, TunnelRegistry.topic())
    assert {:ok, _node, conn_ref, _local_port} = connect(ctx)
    assert_receive {:ssh_server_connection, server_pid}

    :sys.suspend(server_pid)
    assert_receive {:tunnel_down, ^conn_ref}, 5_000
    :sys.resume(server_pid)
  end

  test "fails when the node is not registered in the remote epmd", ctx do
    assert {:error, {:node_not_found, "missing", _names}} =
             connect(ctx, node_name: "missing@#{ctx.node_host}")
  end

  test "fails with a wrong cookie and drops the tunnel", ctx do
    assert {:error, :node_connect_failed} = connect(ctx, cookie: "wrong_cookie")

    node_key = String.to_charlist(ctx.peer_name)
    assert :ets.lookup(TunnelRegistry.table_name(), node_key) == []
  end
end

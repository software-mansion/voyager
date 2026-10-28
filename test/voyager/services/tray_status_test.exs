defmodule Voyager.Services.TrayStatusTest do
  # async: false because the test process takes the global ElixirKit.PubSub name to receive the casts.
  use Voyager.DataCase, async: false

  import Voyager.TestUtils

  alias Voyager.Fakes
  alias Voyager.MCP
  alias Voyager.NodeSession
  alias Voyager.Schemas.Connection
  alias Voyager.Schemas.SshConnection
  alias Voyager.Services.TrayStatus
  alias Voyager.Test.SshKeys

  @node :"shop@10.0.4.12"
  @mcp_url "http://127.0.0.1:4040/mcp"

  setup do
    Process.register(self(), ElixirKit.PubSub)
    start_supervised!({Registry, keys: :duplicate, name: ElixirKit.PubSub.Registry})
    start_supervised!({TrayStatus, native?: true})

    assert %{"connection" => nil, "last_connection" => nil, "connecting" => false} =
             receive_status()

    :ok
  end

  test "follows the node session" do
    connect_node()
    broadcast(NodeSession.topic(), {:node_connected, @node})

    assert %{"connection" => %{"node" => "shop@10.0.4.12", "connector" => "Distribution"}} =
             receive_status()

    broadcast(NodeSession.topic(), {:nodedown, @node, :connection_closed})
    assert %{"connection" => nil} = receive_status()

    broadcast(NodeSession.topic(), {:node_connected, @node})
    assert %{"connection" => %{"node" => "shop@10.0.4.12"}} = receive_status()

    broadcast(NodeSession.topic(), {:node_disconnected, @node, nil})
    assert %{"connection" => nil} = receive_status()
  end

  test "reconnects the last connection and reports the error when it fails" do
    started_here? = not Node.alive?()
    on_exit(fn -> if started_here? and Node.alive?(), do: :net_kernel.stop() end)

    insert!(%Connection{node_name: "gone@127.0.0.1", cookie: "secret"}, 0)
    broadcast(NodeSession.topic(), {:nodedown, @node, :connection_closed})
    assert %{"last_connection" => %{"node" => "gone@127.0.0.1"}} = receive_status()

    send(TrayStatus, "connect")
    assert %{"connecting" => true, "error" => nil} = receive_status()
    assert %{"connecting" => false, "error" => error} = receive_status()
    assert is_binary(error)
  end

  test "ignores connect while the app is connecting" do
    insert!(%Connection{node_name: "saved@127.0.0.1", cookie: "secret"}, 0)
    broadcast(NodeSession.topic(), {:nodedown, @node, :connection_closed})
    assert %{"last_connection" => %{"node" => "saved@127.0.0.1"}} = receive_status()

    broadcast(NodeSession.topic(), {:node_connecting, "saved@127.0.0.1"})
    assert %{"connecting" => true} = receive_status()

    send(TrayStatus, "connect")
    refute_receive {:"$gen_cast", {:broadcast, "tray", _json}}

    broadcast(NodeSession.topic(), {:node_connect_failed, "saved@127.0.0.1", :bad_cookie})
    assert %{"connecting" => false, "error" => error} = receive_status()
    assert is_binary(error)
  end

  test "shows the connection in the same update that ends connecting" do
    broadcast(NodeSession.topic(), {:node_connecting, "shop@10.0.4.12"})
    assert %{"connecting" => true} = receive_status()

    connect_node()
    broadcast(NodeSession.topic(), {:node_connected, @node})

    assert %{"connecting" => false, "connection" => %{"node" => "shop@10.0.4.12"}} =
             receive_status()
  end

  test "ignores connect without a last connection" do
    send(TrayStatus, "connect")
    refute_receive {:"$gen_cast", {:broadcast, "tray", _json}}
  end

  test "reports a failed MCP start" do
    send(TrayStatus, "mcp_on")
    assert %{"error" => error} = receive_status()
    assert is_binary(error)
  end

  test "leaves a stopped MCP server alone on mcp_off" do
    send(TrayStatus, "mcp_off")
    assert %{"mcp" => nil, "error" => nil} = receive_status()
  end

  test "follows the MCP listener" do
    broadcast(MCP.topic(), {:mcp_status, %{alive?: true, url: @mcp_url}})
    assert %{"mcp" => %{"url" => @mcp_url}} = receive_status()

    broadcast(MCP.topic(), {:mcp_status, %{alive?: false, url: @mcp_url}})
    assert %{"mcp" => nil} = receive_status()
  end

  test "offers the latest connection across direct and SSH profiles" do
    insert!(%Connection{node_name: "saved@host", cookie: "secret"}, 3)

    insert!(
      %SshConnection{
        ssh_user: "deploy",
        ssh_host: "gw",
        node_name: "agent@host",
        cookie: "secret"
      },
      2
    )

    broadcast(NodeSession.topic(), {:node_disconnected, @node, nil})

    assert %{
             "last_connection" => %{
               "node" => "agent@host",
               "connector" => "SSH tunnel",
               "host" => "gw"
             }
           } = receive_status()
  end

  test "offers a connection without a saved cookie and reports it on connect" do
    insert!(%Connection{node_name: "nocookie@host"}, 0)
    broadcast(NodeSession.topic(), {:node_disconnected, @node, nil})
    assert %{"last_connection" => %{"node" => "nocookie@host"}} = receive_status()

    send(TrayStatus, "connect")
    assert %{"connecting" => true} = receive_status()
    assert %{"connecting" => false, "error" => error} = receive_status()
    assert is_binary(error)
  end

  test "reports an SSH profile without a saved password on connect" do
    insert!(
      %SshConnection{
        ssh_user: "deploy",
        ssh_host: "gw",
        node_name: "nopassword@host",
        cookie: "secret",
        auth_method: :password
      },
      0
    )

    broadcast(NodeSession.topic(), {:node_disconnected, @node, nil})
    assert %{"last_connection" => %{"node" => "nopassword@host"}} = receive_status()

    send(TrayStatus, "connect")
    assert %{"connecting" => true} = receive_status()
    assert %{"connecting" => false, "error" => error} = receive_status()
    assert is_binary(error)
  end

  test "reconnects an SSH agent profile with a saved socket" do
    enable_proxy_epmd(%{})

    insert!(
      %SshConnection{
        ssh_user: "deploy",
        ssh_host: "gw",
        node_name: "no_at_sign",
        cookie: "secret",
        auth_method: :agent,
        agent_socket_path: "~/.1password/agent.sock"
      },
      0
    )

    broadcast(NodeSession.topic(), {:node_disconnected, @node, nil})
    assert %{"last_connection" => %{"node" => "no_at_sign"}} = receive_status()

    send(TrayStatus, "connect")
    assert %{"connecting" => true} = receive_status()
    assert %{"connecting" => false, "error" => error} = receive_status()
    assert error =~ "name@host"
  end

  @tag :tmp_dir
  test "reports a passphrase-protected key on connect", %{tmp_dir: dir} do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    {path, _public_key} = SshKeys.pem!(dir, "id_ecdsa", key, "test-passphrase")

    insert!(
      %SshConnection{
        ssh_user: "deploy",
        ssh_host: "gw",
        node_name: "key@host",
        cookie: "secret",
        auth_method: :key,
        key_path: path
      },
      0
    )

    broadcast(NodeSession.topic(), {:node_disconnected, @node, nil})
    assert %{"last_connection" => %{"node" => "key@host"}} = receive_status()

    send(TrayStatus, "connect")
    assert %{"connecting" => true} = receive_status()
    assert %{"connecting" => false, "error" => error} = receive_status()
    assert error =~ "passphrase"
  end

  defp insert!(connection, hours_ago) do
    at = DateTime.utc_now() |> DateTime.add(-hours_ago, :hour) |> DateTime.truncate(:second)
    Repo.insert!(%{connection | last_connected_at: at})
  end

  defp connect_node, do: Fakes.connect_node!(Fakes.node_session(node: @node))

  defp broadcast(topic, message), do: Phoenix.PubSub.broadcast(Voyager.PubSub, topic, message)

  defp receive_status do
    assert_receive {:"$gen_cast", {:broadcast, "tray", json}}
    JSON.decode!(json)
  end
end

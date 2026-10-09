defmodule Voyager.Services.TrayStatusTest do
  # async: false because the test process takes the global ElixirKit.PubSub name to receive the casts.
  use Voyager.DataCase, async: false

  alias Voyager.MCP
  alias Voyager.NodeSession
  alias Voyager.Schemas.Connection
  alias Voyager.Schemas.SshConnection
  alias Voyager.Services.TrayStatus

  @node :"shop@10.0.4.12"
  @mcp_url "http://127.0.0.1:4040/mcp"

  setup do
    Process.register(self(), ElixirKit.PubSub)
    start_supervised!({Registry, keys: :duplicate, name: ElixirKit.PubSub.Registry})
    start_supervised!({TrayStatus, native?: true})

    assert %{"node" => nil, "node_lost" => false, "connector" => nil} = receive_status()
    :ok
  end

  test "follows the node session" do
    broadcast(NodeSession.topic(), {:node_connected, @node})
    assert %{"node" => "shop@10.0.4.12", "node_lost" => false} = receive_status()

    broadcast(NodeSession.topic(), {:nodedown, @node, :connection_closed})
    assert %{"node" => "shop@10.0.4.12", "node_lost" => true} = receive_status()

    broadcast(NodeSession.topic(), {:node_connected, @node})
    assert %{"node_lost" => false} = receive_status()

    broadcast(NodeSession.topic(), {:node_disconnected, @node, nil})
    assert %{"node" => nil, "node_lost" => false} = receive_status()
  end

  test "accepts connect after the node is lost" do
    broadcast(NodeSession.topic(), {:nodedown, @node, :connection_closed})
    assert %{"node_lost" => true} = receive_status()

    send(TrayStatus, "connect")
    assert %{"node_lost" => true, "connecting" => false} = receive_status()
  end

  test "follows the MCP listener" do
    broadcast(MCP.topic(), {:mcp_status, %{alive?: true, url: @mcp_url}})
    assert %{"mcp_url" => @mcp_url} = receive_status()

    broadcast(MCP.topic(), {:mcp_status, %{alive?: false, url: @mcp_url}})
    assert %{"mcp_url" => nil} = receive_status()
  end

  test "offers the latest connection that has every credential saved" do
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

    insert!(
      %SshConnection{
        ssh_user: "deploy",
        ssh_host: "gw",
        node_name: "nopass@host",
        cookie: "secret",
        auth_method: :password
      },
      1
    )

    insert!(%Connection{node_name: "nocookie@host"}, 0)

    send(TrayStatus, "refresh")

    assert %{
             "last_connected" => %{
               "node" => "agent@host",
               "connector" => "SSH tunnel",
               "host" => "gw"
             }
           } = receive_status()
  end

  test "has no connection to offer when none can reconnect unattended" do
    insert!(%Connection{node_name: "nocookie@host"}, 0)

    send(TrayStatus, "refresh")

    assert %{"last_connected" => nil} = receive_status()
  end

  defp insert!(connection, hours_ago) do
    at = DateTime.utc_now() |> DateTime.add(-hours_ago, :hour) |> DateTime.truncate(:second)
    Repo.insert!(%{connection | last_connected_at: at})
  end

  defp broadcast(topic, message), do: Phoenix.PubSub.broadcast(Voyager.PubSub, topic, message)

  defp receive_status do
    assert_receive {:"$gen_cast", {:broadcast, "tray", json}}
    JSON.decode!(json)
  end
end

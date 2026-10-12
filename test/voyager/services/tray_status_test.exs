defmodule Voyager.Services.TrayStatusTest do
  # async: false because the test process takes the global ElixirKit.PubSub name to receive the casts.
  use Voyager.DataCase, async: false

  alias Voyager.Fakes
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
    insert!(%Connection{node_name: "gone@127.0.0.1", cookie: "secret"}, 0)
    broadcast(NodeSession.topic(), {:nodedown, @node, :connection_closed})
    assert %{"last_connection" => %{"node" => "gone@127.0.0.1"}} = receive_status()

    send(TrayStatus, "connect")
    assert %{"connecting" => true, "error" => nil} = receive_status()
    assert %{"connecting" => false, "error" => error} = receive_status()
    assert is_binary(error)
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

  test "has no connection to offer when none can reconnect unattended" do
    insert!(%Connection{node_name: "nocookie@host"}, 0)

    broadcast(NodeSession.topic(), {:node_disconnected, @node, nil})

    assert %{"last_connection" => nil} = receive_status()
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

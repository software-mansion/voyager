defmodule Voyager.MCP.Tools.ListConnectionsTest do
  # async: false because the tool reads the global `Voyager.NodeSession`.
  use Voyager.DataCase, async: false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.Fakes
  alias Voyager.MCP.Tools.ListConnections
  alias Voyager.NodeSession
  alias Voyager.NodeSession.Connectors.Ssh, as: SshConnector
  alias Voyager.Schemas.Connection
  alias Voyager.Schemas.SshConnection

  setup do
    previous_state = :sys.get_state(NodeSession)
    Fakes.put_session(nil)
    on_exit(fn -> :sys.replace_state(NodeSession, fn _ -> previous_state end) end)
  end

  test "never returns stored secrets" do
    insert!(%Connection{node_name: "shop@10.0.4.12", cookie: "top-secret"}, 0)

    insert!(
      %SshConnection{
        ssh_user: "deploy",
        ssh_host: "gw",
        node_name: "shop@127.0.0.1",
        cookie: "top-secret",
        auth_method: :password,
        password: "hunter2"
      },
      1
    )

    json = run_json()

    refute json =~ "top-secret"
    refute json =~ "hunter2"
  end

  test "lists pinned connections first, then the most recent" do
    old_pinned = insert!(%Connection{node_name: "pinned@host", pinned: true}, 5)
    recent = insert!(%Connection{node_name: "recent@host"}, 0)
    ssh = insert!(%SshConnection{ssh_user: "deploy", ssh_host: "gw", node_name: "ssh@host"}, 1)

    assert ids() == ["direct:#{old_pinned.id}", "direct:#{recent.id}", "ssh:#{ssh.id}"]
  end

  test "flags connections missing a secret" do
    insert!(%Connection{node_name: "nocookie@host"}, 0)
    insert!(%Connection{node_name: "cookie@host", cookie: "secret"}, 1)

    insert!(
      %SshConnection{
        ssh_user: "deploy",
        ssh_host: "gw",
        node_name: "nopass@host",
        cookie: "secret",
        auth_method: :password
      },
      2
    )

    insert!(
      %SshConnection{ssh_user: "deploy", ssh_host: "gw", node_name: "agent@host", cookie: "s"},
      3
    )

    assert needs_input() == %{
             "nocookie@host" => true,
             "cookie@host" => false,
             "nopass@host" => true,
             "agent@host" => false
           }
  end

  test "marks the connected row, matching SSH sessions on the host too" do
    insert!(%SshConnection{ssh_user: "deploy", ssh_host: "a", node_name: "app@127.0.0.1"}, 0)
    insert!(%SshConnection{ssh_user: "deploy", ssh_host: "b", node_name: "app@127.0.0.1"}, 1)

    session = Fakes.node_session(node_name: "app@127.0.0.1", connector: SshConnector)
    meta = %{ssh_user: "deploy", ssh_host: "a", ssh_port: 22, epmd_port: 4369}
    Fakes.put_session(%{session | meta: meta})

    assert [%{"connected" => true, "ssh" => %{"host" => "a"}}, %{"connected" => false}] =
             run()["connections"]
  end

  defp insert!(connection, hours_ago) do
    at = DateTime.utc_now() |> DateTime.add(-hours_ago, :hour) |> DateTime.truncate(:second)
    Repo.insert!(%{connection | last_connected_at: at})
  end

  defp ids, do: Enum.map(run()["connections"], & &1["id"])

  defp needs_input do
    Map.new(run()["connections"], &{&1["node_name"], &1["needs_user_input"]})
  end

  defp run, do: JSON.decode!(run_json())

  defp run_json do
    assert {:reply, %Response{isError: false, content: [%{"text" => json}]}, %Frame{}} =
             ListConnections.execute(%{}, %Frame{})

    json
  end
end

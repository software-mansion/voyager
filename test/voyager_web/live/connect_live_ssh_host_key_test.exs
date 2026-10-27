defmodule VoyagerWeb.ConnectLiveSshHostKeyTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Voyager.TestUtils

  alias Voyager.Fakes
  alias Voyager.NodeSession
  alias Voyager.Test.SshServer

  @moduletag :tmp_dir
  @moduletag capture_log: true

  setup :enable_proxy_epmd

  setup %{tmp_dir: tmp_dir} do
    previous_state = :sys.get_state(NodeSession)
    Fakes.put_session(nil)
    known_hosts = Path.join(tmp_dir, "known_hosts")
    Application.put_env(:voyager, :known_hosts_path, known_hosts)

    on_exit(fn ->
      :sys.replace_state(NodeSession, fn _ -> previous_state end)
      Application.delete_env(:voyager, :known_hosts_path)
    end)

    %{known_hosts: known_hosts, server: SshServer.start!({127, 0, 0, 1})}
  end

  defp submit_connect(view, server, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          "ssh_user" => SshServer.user(),
          "ssh_host" => "127.0.0.1",
          "ssh_port" => to_string(server.port),
          "node_name" => "demo@127.0.0.1",
          "cookie" => "secret",
          "auth_method" => "password",
          "password" => "wrong"
        },
        overrides
      )

    view |> element("#ssh-connect-form") |> render_submit(%{"ssh" => params})
    render_async(view)
  end

  test "asks to trust an unknown host key before sending the password", %{
    conn: conn,
    server: server
  } do
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, server)

    assert view |> element("#ssh-host-key-modal-fingerprint") |> render() =~ server.fingerprint
    assert has_element?(view, "#ssh-host-key-modal-password-warning")
    refute_received {:ssh_server_connection, _pid}
  end

  test "does not warn about the password for agent auth", %{conn: conn, server: server} do
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, server, %{"auth_method" => "agent"})

    assert has_element?(view, "#ssh-host-key-modal")
    refute has_element?(view, "#ssh-host-key-modal-password-warning")
  end

  test "pins the key and connects once trusted", %{
    conn: conn,
    server: server,
    known_hosts: known_hosts
  } do
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, server)

    view |> element("#ssh-host-key-modal-accept") |> render_click()
    render_async(view)

    refute has_element?(view, "#ssh-host-key-modal")
    assert has_element?(view, "#ssh_ssh_user.input-error")
    assert File.read!(known_hosts) =~ "[127.0.0.1]:#{server.port} "
  end

  test "rejecting keeps the key unpinned", %{conn: conn, server: server, known_hosts: known_hosts} do
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, server)

    view |> element("#ssh-host-key-modal-reject") |> render_click()

    refute has_element?(view, "#ssh-host-key-modal")
    refute File.exists?(known_hosts)
  end

  test "marks the host when its key changed", %{
    conn: conn,
    server: server,
    known_hosts: known_hosts
  } do
    other_key =
      :public_key.generate_key({:namedCurve, :ed25519}) |> :ssh_file.extract_public_key()

    host = String.to_charlist("[127.0.0.1]:#{server.port}")
    File.write!(known_hosts, :ssh_file.encode([{other_key, [hostnames: [host]]}], :known_hosts))

    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, server)

    refute has_element?(view, "#ssh-host-key-modal")
    assert has_element?(view, "#ssh_ssh_host.input-error")
  end
end

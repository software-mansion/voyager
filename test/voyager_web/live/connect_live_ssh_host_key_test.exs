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
    render_async(view, 2_000)
  end

  test "asks to trust an unknown host key before sending the password", %{
    conn: conn,
    server: server
  } do
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, server)

    assert view |> element("#ssh-host-key-modal-fingerprint") |> render() =~ server.fingerprint

    assert has_element?(
             view,
             "#ssh-host-key-modal-fingerprint-copy[data-copy-target='#ssh-host-key-modal-fingerprint']"
           )

    assert has_element?(view, "#ssh-host-key-modal-password-warning")
    refute has_element?(view, "#flash-error")
    refute_received {:ssh_server_connection, _pid}
  end

  test "brackets an IPv6 host in the prompt", %{conn: conn} do
    server = SshServer.start!({0, 0, 0, 0, 0, 0, 0, 1})
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, server, %{"ssh_host" => "::1"})

    assert view |> element("#ssh-host-key-modal") |> render() =~ "@[::1]:#{server.port}"
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
    render_async(view, 2_000)

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

  test "warns about a changed key and removes the old one from Voyager's file", %{
    conn: conn,
    server: server,
    known_hosts: known_hosts
  } do
    write_other_key!(known_hosts, server)

    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, server)

    assert text(view, "#ssh-host-key-changed-modal-fingerprint") == server.fingerprint
    assert text(view, "#ssh-host-key-changed-modal-location") == known_hosts

    refute has_element?(view, "#ssh-host-key-changed-modal-command")
    assert has_element?(view, "#ssh_ssh_host.input-error")
    refute has_element?(view, "#flash-error")

    view |> element("#ssh-host-key-changed-modal-remove") |> render_click()
    render_async(view, 2_000)

    refute has_element?(view, "#ssh-host-key-changed-modal")
    refute has_element?(view, "#ssh_ssh_host.input-error")
    assert File.read!(known_hosts) == ""
    assert view |> element("#ssh-host-key-modal-fingerprint") |> render() =~ server.fingerprint
  end

  test "keeps the dialog open when the old key can't be removed", %{
    conn: conn,
    server: server,
    known_hosts: known_hosts
  } do
    write_other_key!(known_hosts, server)
    File.chmod!(known_hosts, 0o400)
    on_exit(fn -> File.chmod(known_hosts, 0o600) end)
    before = File.read!(known_hosts)

    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, server)

    view |> element("#ssh-host-key-changed-modal-remove") |> render_click()

    assert has_element?(view, "#ssh-host-key-changed-modal-remove")

    assert text(view, "#ssh-host-key-changed-modal-remove-error") ==
             "Couldn't remove the old key from #{known_hosts} — check its permissions"

    assert has_element?(view, "#ssh-connect-form", "SSH host key changed")
    refute has_element?(view, "#ssh-connect-form", "Can't save the host key")
    assert File.read!(known_hosts) == before

    view |> element("#ssh-host-key-changed-modal-dismiss") |> render_click()
    refute has_element?(view, "#ssh-host-key-changed-modal")

    submit_connect(view, server)
    assert has_element?(view, "#ssh-host-key-changed-modal-remove")
    refute has_element?(view, "#ssh-host-key-changed-modal-remove-error")
  end

  test "keeps the dialog open when the old key can't be read", %{
    conn: conn,
    server: server,
    known_hosts: known_hosts
  } do
    write_other_key!(known_hosts, server)
    on_exit(fn -> File.chmod(known_hosts, 0o600) end)

    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, server)
    File.chmod!(known_hosts, 0o000)

    view |> element("#ssh-host-key-changed-modal-remove") |> render_click()

    assert has_element?(view, "#ssh-host-key-changed-modal-remove")

    assert text(view, "#ssh-host-key-changed-modal-remove-error") ==
             "Couldn't remove the old key — can't read #{known_hosts}"

    refute has_element?(view, "#ssh-connect-form", "Can't save the host key")
    assert File.exists?(known_hosts)
  end

  test "shows the ssh-keygen command for a changed key in another file", %{
    conn: conn,
    server: server,
    tmp_dir: tmp_dir
  } do
    home = System.get_env("HOME")
    System.put_env("HOME", tmp_dir)
    on_exit(fn -> System.put_env("HOME", home) end)
    system_known_hosts = Path.join([tmp_dir, ".ssh", "known_hosts"])
    write_other_key!(system_known_hosts, server)

    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, server)

    assert text(view, "#ssh-host-key-changed-modal-command") ==
             "ssh-keygen -f '#{system_known_hosts}' -R '[127.0.0.1]:#{server.port}'"

    refute has_element?(view, "#ssh-host-key-changed-modal-remove")

    view |> element("#ssh-host-key-changed-modal-dismiss") |> render_click()

    refute has_element?(view, "#ssh-host-key-changed-modal")
    assert has_element?(view, "#ssh_ssh_host.input-error")
    assert File.exists?(system_known_hosts)
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  defp write_other_key!(path, server) do
    other_key =
      :public_key.generate_key({:namedCurve, :ed25519}) |> :ssh_file.extract_public_key()

    host = String.to_charlist("[127.0.0.1]:#{server.port}")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :ssh_file.encode([{other_key, [hostnames: [host]]}], :known_hosts))
  end

  test "marks the host when the trusted key can't be saved", %{
    conn: conn,
    server: server,
    known_hosts: known_hosts
  } do
    File.write!(known_hosts, "")
    File.chmod!(known_hosts, 0o400)
    on_exit(fn -> File.chmod(known_hosts, 0o600) end)

    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, server)

    view |> element("#ssh-host-key-modal-accept") |> render_click()
    render_async(view, 2_000)

    refute has_element?(view, "#ssh-host-key-modal")
    assert has_element?(view, "#ssh_ssh_host.input-error")
    refute has_element?(view, "#ssh_ssh_user.input-error")
  end
end

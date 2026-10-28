defmodule VoyagerWeb.ConnectLiveSshKeyTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Fakes
  alias Voyager.NodeSession
  alias Voyager.Test.SshKeys

  @moduletag :tmp_dir
  @passphrase "test-passphrase"

  setup do
    previous_state = :sys.get_state(NodeSession)
    Fakes.put_session(nil)
    on_exit(fn -> :sys.replace_state(NodeSession, fn _ -> previous_state end) end)
  end

  defp ssh_params(key_path) do
    %{
      "ssh_user" => "deploy",
      "ssh_host" => "gw",
      "node_name" => "demo@localhost",
      "cookie" => "secret",
      "auth_method" => "key",
      "key_path" => key_path
    }
  end

  defp pick_key(view, key_path) do
    view
    |> element("#ssh-connect-form")
    |> render_change(%{"ssh" => %{"auth_method" => "key", "key_path" => key_path}})
  end

  defp submit_connect(view, key_path) do
    view |> element("#ssh-connect-form") |> render_submit(%{"ssh" => ssh_params(key_path)})
  end

  defp submit_passphrase(view, passphrase) do
    view
    |> element("#ssh-passphrase-modal-form")
    |> render_submit(%{"passphrase" => %{"passphrase" => passphrase}})
  end

  defp encrypted_pem!(dir) do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    {path, _public_key} = SshKeys.pem!(dir, "id_ecdsa", key, @passphrase)
    path
  end

  test "keeps the identity file when switching auth method", %{conn: conn, tmp_dir: dir} do
    path = encrypted_pem!(dir)
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    pick_key(view, path)

    for auth_method <- ["agent", "key"] do
      view
      |> element("#ssh-connect-form")
      |> render_change(%{"ssh" => %{"auth_method" => auth_method}})
    end

    assert has_element?(view, ~s|#ssh_key_path[value="#{path}"]|)
  end

  test "marks only the identity file for a passphrase-protected OpenSSH key", %{
    conn: conn,
    tmp_dir: dir
  } do
    {path, _public_key} =
      SshKeys.ssh_keygen!(dir, "id_ed25519", ~w(-t ed25519 -a 1 -N #{@passphrase}))

    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    pick_key(view, path)

    assert has_element?(view, "#ssh_key_path.input-error")
    refute has_element?(view, "#ssh_node_name.input-error")
  end

  test "marks the identity file for a missing file", %{conn: conn, tmp_dir: dir} do
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    pick_key(view, Path.join(dir, "missing"))

    assert has_element?(view, "#ssh_key_path.input-error")
  end

  test "keeps the identity file error next to the other errors on connect", %{
    conn: conn,
    tmp_dir: dir
  } do
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")

    view
    |> element("#ssh-connect-form")
    |> render_submit(%{
      "ssh" => %{"auth_method" => "key", "key_path" => Path.join(dir, "missing")}
    })

    assert has_element?(view, "#ssh_key_path.input-error")
    assert has_element?(view, "#ssh_node_name.input-error")
  end

  test "an encrypted key needs no passphrase until connect", %{conn: conn, tmp_dir: dir} do
    path = encrypted_pem!(dir)
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")

    pick_key(view, path)
    refute has_element?(view, "#ssh_key_path.input-error")
    refute has_element?(view, "#ssh-passphrase-modal")

    submit_connect(view, path)
    assert has_element?(view, "#ssh-passphrase-modal")
  end

  test "keeps the passphrase modal open on a wrong passphrase", %{conn: conn, tmp_dir: dir} do
    path = encrypted_pem!(dir)
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, path)

    submit_passphrase(view, "wrong-passphrase")

    assert has_element?(view, "#ssh-passphrase-modal")
    assert has_element?(view, "#passphrase_passphrase.input-error")
  end

  test "connects once the passphrase is right", %{conn: conn, tmp_dir: dir} do
    path = encrypted_pem!(dir)
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, path)

    submit_passphrase(view, @passphrase)
    refute has_element?(view, "#ssh-passphrase-modal")

    render_async(view)
    assert has_element?(view, "#ssh_node_name.input-error")
  end

  test "closes the passphrase modal on cancel", %{conn: conn, tmp_dir: dir} do
    path = encrypted_pem!(dir)
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, path)

    view |> element("#ssh-passphrase-modal-cancel") |> render_click()

    refute has_element?(view, "#ssh-passphrase-modal")
  end

  test "marks the identity file when the key disappears behind the modal", %{
    conn: conn,
    tmp_dir: dir
  } do
    path = encrypted_pem!(dir)
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    submit_connect(view, path)
    File.rm!(path)

    submit_passphrase(view, @passphrase)

    refute has_element?(view, "#ssh-passphrase-modal")
    assert has_element?(view, "#ssh_key_path.input-error")
  end
end

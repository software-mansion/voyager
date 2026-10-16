defmodule Voyager.Services.SSH.ErlsshTest do
  # async: false because the test points HOME, which :ssh_file reads for known_hosts, at a tmp dir.
  use ExUnit.Case, async: false

  alias Voyager.Services.SSH.Erlssh
  alias Voyager.Test.SshKeys
  alias Voyager.Test.SshServer

  @loopback {127, 0, 0, 1}
  @passphrase "test-passphrase"

  setup %{tmp_dir: tmp_dir} do
    home = System.get_env("HOME")
    System.put_env("HOME", tmp_dir)
    on_exit(fn -> System.put_env("HOME", home) end)
  end

  @tag :tmp_dir
  test "does not save the accepted host key to known_hosts", %{tmp_dir: tmp_dir} do
    %{port: port} = SshServer.start!({127, 0, 0, 1})

    assert {:ok, conn} =
             Erlssh.connect(
               "127.0.0.1",
               port,
               SshServer.user(),
               {:password, SshServer.password()}
             )

    Erlssh.close(conn)
    refute File.exists?(Path.join([tmp_dir, ".ssh", "known_hosts"]))
  end

  describe "key file auth" do
    @describetag :tmp_dir

    test "logs in with an OpenSSH key", %{tmp_dir: dir} do
      {path, public_key} = SshKeys.ssh_keygen!(dir, "id_ed25519", ["-t", "ed25519", "-N", ""])
      %{port: port} = SshServer.start!(@loopback, authorized_keys: [public_key])

      assert {:ok, conn} = connect_with_key(port, path, nil)
      Erlssh.close(conn)
    end

    test "logs in with an RSA key", %{tmp_dir: dir} do
      key = :public_key.generate_key({:rsa, 2048, 65_537})
      {path, public_key} = SshKeys.pem!(dir, "id_rsa", key)
      %{port: port} = SshServer.start!(@loopback, authorized_keys: [public_key])

      assert {:ok, conn} = connect_with_key(port, path, nil)
      Erlssh.close(conn)
    end

    test "logs in with an encrypted PEM key and its passphrase", %{tmp_dir: dir} do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      {path, public_key} = SshKeys.pem!(dir, "id_ecdsa", key, @passphrase)
      %{port: port} = SshServer.start!(@loopback, authorized_keys: [public_key])

      assert {:ok, conn} = connect_with_key(port, path, @passphrase)
      Erlssh.close(conn)
    end

    test "fails with a key the server does not accept", %{tmp_dir: dir} do
      {path, _public_key} = SshKeys.ssh_keygen!(dir, "id_ed25519", ["-t", "ed25519", "-N", ""])
      %{port: port} = SshServer.start!(@loopback)

      assert {:error, _reason} = connect_with_key(port, path, nil)
    end
  end

  defp connect_with_key(port, path, passphrase),
    do: Erlssh.connect("127.0.0.1", port, SshServer.user(), {:key, path, passphrase})
end

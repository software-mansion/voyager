defmodule Voyager.Services.SSH.KeyFileTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.SSH.KeyFile
  alias Voyager.Test.SshKeys

  @moduletag :tmp_dir
  @passphrase "test-passphrase"
  @unencrypted_ed25519 ["-t", "ed25519", "-N", ""]

  defp ec_key, do: :public_key.generate_key({:namedCurve, :secp256r1})

  describe "check/2" do
    test "accepts an unencrypted OpenSSH key", %{tmp_dir: dir} do
      {path, _pub} = SshKeys.ssh_keygen!(dir, "id_ed25519", @unencrypted_ed25519)

      assert KeyFile.check(path, nil) == :ok
    end

    test "rejects a passphrase-protected OpenSSH key, with or without the passphrase", %{
      tmp_dir: dir
    } do
      {path, _pub} = SshKeys.ssh_keygen!(dir, "id_ed25519", ~w(-t ed25519 -a 1 -N #{@passphrase}))

      assert KeyFile.check(path, nil) == {:error, :key_encrypted_openssh}
      assert KeyFile.check(path, @passphrase) == {:error, :key_encrypted_openssh}
    end

    test "accepts an unencrypted PEM key", %{tmp_dir: dir} do
      {path, _pub} = SshKeys.pem!(dir, "id_ecdsa", ec_key())

      assert KeyFile.check(path, nil) == :ok
    end

    test "asks for the passphrase of an encrypted PEM key", %{tmp_dir: dir} do
      {path, _pub} = SshKeys.pem!(dir, "id_ecdsa", ec_key(), @passphrase)

      assert KeyFile.check(path, nil) == {:error, :key_passphrase_required}
      assert KeyFile.check(path, "wrong-passphrase") == {:error, :key_bad_passphrase}
      assert KeyFile.check(path, @passphrase) == :ok
    end

    test "decrypts an encrypted PKCS#8 key", %{tmp_dir: dir} do
      {path, _pub} = SshKeys.ssh_keygen!(dir, "id_rsa", ~w(-t rsa -m PKCS8 -N #{@passphrase}))

      assert KeyFile.check(path, nil) == {:error, :key_passphrase_required}
      assert KeyFile.check(path, @passphrase) == :ok
    end

    test "rejects a public key", %{tmp_dir: dir} do
      {path, _pub} = SshKeys.ssh_keygen!(dir, "id_ed25519", @unencrypted_ed25519)

      assert KeyFile.check(path <> ".pub", nil) == {:error, :key_unreadable}
    end

    test "rejects a file that is not a key", %{tmp_dir: dir} do
      path = Path.join(dir, "notes.txt")
      File.write!(path, "Host demo\n")

      assert KeyFile.check(path, nil) == {:error, :key_unreadable}
    end

    test "rejects a corrupted OpenSSH key", %{tmp_dir: dir} do
      path = Path.join(dir, "id_broken")

      File.write!(
        path,
        "-----BEGIN OPENSSH PRIVATE KEY-----\nbm90IGEga2V5\n-----END OPENSSH PRIVATE KEY-----\n"
      )

      assert KeyFile.check(path, nil) == {:error, :key_unreadable}
    end

    test "reports a missing file", %{tmp_dir: dir} do
      path = Path.join(dir, "missing")

      assert KeyFile.check(path, nil) == {:error, {:read_failed, {path, :enoent}}}
    end
  end

  describe "user_key/2" do
    test "returns the key only for an algorithm it can sign", %{tmp_dir: dir} do
      {path, public_key} = SshKeys.pem!(dir, "id_ecdsa", ec_key())
      opts = [key_cb_private: [path: path, passphrase: nil]]

      assert {:ok, key} = KeyFile.user_key(:"ecdsa-sha2-nistp256", opts)
      assert :ssh_file.extract_public_key(key) == public_key
      assert KeyFile.user_key(:"ssh-ed25519", opts) == {:error, :no_key_found}
    end
  end
end

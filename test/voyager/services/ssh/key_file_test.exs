defmodule Voyager.Services.SSH.KeyFileTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.SSH.KeyFile
  alias Voyager.Test.SshKeys

  @moduletag :tmp_dir
  @passphrase "test-passphrase"
  @unencrypted_ed25519 ["-t", "ed25519", "-N", ""]

  defp ec_key, do: :public_key.generate_key({:namedCurve, :secp256r1})

  defp assert_decrypts(path, public_key) do
    assert KeyFile.decode(path, nil) == {:error, :key_passphrase_required}
    assert KeyFile.decode(path, "wrong-passphrase") == {:error, :key_bad_passphrase}
    assert KeyFile.decode(path, "") == {:error, :key_bad_passphrase}
    assert {:ok, key} = KeyFile.decode(path, @passphrase)
    assert :ssh_file.extract_public_key(key) == public_key
  end

  describe "decode/2" do
    test "accepts an unencrypted OpenSSH key", %{tmp_dir: dir} do
      {path, public_key} = SshKeys.ssh_keygen!(dir, "id_ed25519", @unencrypted_ed25519)

      assert {:ok, key} = KeyFile.decode(path, nil)
      assert :ssh_file.extract_public_key(key) == public_key
    end

    test "decrypts an OpenSSH key with several bcrypt rounds", %{tmp_dir: dir} do
      {path, public_key} = SshKeys.ssh_keygen!(dir, "id", ~w(-t ed25519 -a 3 -N #{@passphrase}))

      assert_decrypts(path, public_key)
    end

    test "rejects an OpenSSH key with a cipher other than aes256-ctr", %{tmp_dir: dir} do
      {path, _pub} =
        SshKeys.ssh_keygen!(dir, "id", ~w(-t ed25519 -a 1 -Z aes128-ctr -N #{@passphrase}))

      assert KeyFile.decode(path, nil) == {:error, :key_unsupported_cipher}
    end

    test "accepts an unencrypted PEM key", %{tmp_dir: dir} do
      {path, _pub} = SshKeys.pem!(dir, "id_ecdsa", ec_key())

      assert {:ok, _key} = KeyFile.decode(path, nil)
    end

    test "asks for the passphrase of an encrypted PEM key", %{tmp_dir: dir} do
      {path, public_key} = SshKeys.pem!(dir, "id_ecdsa", ec_key(), @passphrase)

      assert_decrypts(path, public_key)
    end

    test "decrypts an encrypted PKCS#8 key", %{tmp_dir: dir} do
      {path, public_key} =
        SshKeys.ssh_keygen!(dir, "id_rsa", ~w(-t rsa -m PKCS8 -N #{@passphrase}))

      assert_decrypts(path, public_key)
    end

    test "rejects a public key", %{tmp_dir: dir} do
      {path, _pub} = SshKeys.ssh_keygen!(dir, "id_ed25519", @unencrypted_ed25519)

      assert KeyFile.decode(path <> ".pub", nil) == {:error, :key_unreadable}
    end

    test "rejects a file that is not a key", %{tmp_dir: dir} do
      path = Path.join(dir, "notes.txt")
      File.write!(path, "Host demo\n")

      assert KeyFile.decode(path, nil) == {:error, :key_unreadable}
    end

    test "rejects a corrupted OpenSSH key", %{tmp_dir: dir} do
      path = Path.join(dir, "id_broken")

      File.write!(
        path,
        "-----BEGIN OPENSSH PRIVATE KEY-----\nbm90IGEga2V5\n-----END OPENSSH PRIVATE KEY-----\n"
      )

      assert KeyFile.decode(path, nil) == {:error, :key_unreadable}
    end

    test "reports a missing file", %{tmp_dir: dir} do
      path = Path.join(dir, "missing")

      assert KeyFile.decode(path, nil) == {:error, {:read_failed, {path, :enoent}}}
    end
  end

  describe "user_key/2" do
    test "returns the key only for an algorithm it can sign" do
      key = ec_key()
      opts = [key_cb_private: [key: key]]

      assert KeyFile.user_key(:"ecdsa-sha2-nistp256", opts) == {:ok, key}
      assert KeyFile.user_key(:"ssh-ed25519", opts) == {:error, :no_key_found}
    end
  end
end

defmodule Voyager.Services.SSH.KeyFileTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.SSH.KeyFile
  alias Voyager.Test.SshKeys

  @moduletag :tmp_dir
  @passphrase "test-passphrase"
  @unencrypted_ed25519 ["-t", "ed25519", "-N", ""]

  defp ec_key, do: :public_key.generate_key({:namedCurve, :secp256r1})

  defp write_openssh_key(dir, name, rounds) do
    salt = <<0::16*8>>
    kdf_options = <<byte_size(salt)::32, salt::binary, rounds::32>>

    body =
      IO.iodata_to_binary([
        "openssh-key-v1\0",
        ssh_string("aes256-ctr"),
        ssh_string("bcrypt"),
        ssh_string(kdf_options),
        <<0::32>>,
        ssh_string(<<0::64>>)
      ])

    path = Path.join(dir, name)

    File.write!(path, """
    -----BEGIN OPENSSH PRIVATE KEY-----
    #{Base.encode64(body)}
    -----END OPENSSH PRIVATE KEY-----
    """)

    path
  end

  defp ssh_string(value), do: <<byte_size(value)::32, value::binary>>

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

    @tag timeout: 5_000
    test "rejects an OpenSSH key whose bcrypt rounds exceed the cap", %{tmp_dir: dir} do
      path = write_openssh_key(dir, "id_huge_rounds", 0xFFFFFFFF)

      assert KeyFile.decode(path, nil) == {:error, :key_unreachable}
      assert KeyFile.decode(path, @passphrase) == {:error, :key_unreachable}
    end

    test "asks for a passphrase when bcrypt rounds are at the cap", %{tmp_dir: dir} do
      path = write_openssh_key(dir, "id_max_rounds", 1_000)

      assert KeyFile.decode(path, nil) == {:error, :key_passphrase_required}
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

    test "refuses a path that is not a regular file", %{tmp_dir: dir} do
      assert KeyFile.decode(dir, nil) == {:error, {:read_failed, {dir, :not_regular_file}}}
    end

    test "refuses a file too large to be a key", %{tmp_dir: dir} do
      path = Path.join(dir, "huge")
      File.write!(path, :binary.copy("#", 1_048_577))

      assert KeyFile.decode(path, nil) == {:error, {:read_failed, {path, :too_large}}}
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

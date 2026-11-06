defmodule Voyager.Services.SSH.KnownHostsTest do
  # async: false because the test points HOME, which is read for the system known_hosts, at a tmp dir.
  use ExUnit.Case, async: false

  alias Voyager.Services.SSH.KnownHosts

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    home = System.get_env("HOME")
    configured_global = Application.fetch_env!(:voyager, :global_known_hosts_path)
    System.put_env("HOME", tmp_dir)
    voyager = Path.join(tmp_dir, "voyager_known_hosts")
    global = Path.join(tmp_dir, "ssh_known_hosts")
    Application.put_env(:voyager, :known_hosts_path, voyager)
    Application.put_env(:voyager, :global_known_hosts_path, global)

    on_exit(fn ->
      System.put_env("HOME", home)
      Application.delete_env(:voyager, :known_hosts_path)
      Application.put_env(:voyager, :global_known_hosts_path, configured_global)
    end)

    File.mkdir_p!(Path.join(tmp_dir, ".ssh"))

    %{
      global: global,
      system: Path.join([tmp_dir, ".ssh", "known_hosts"]),
      voyager: voyager,
      key: ed25519()
    }
  end

  defp ed25519,
    do: :public_key.generate_key({:namedCurve, :ed25519}) |> :ssh_file.extract_public_key()

  defp opts(host), do: [key_cb_private: [host: host, notify: {self(), make_ref()}]]

  defp host_key?(key, host, port \\ 22),
    do:
      KnownHosts.is_host_key(key, [~c"10.0.0.5", {10, 0, 0, 5}], port, :"ssh-ed25519", opts(host))

  defp line(key, host),
    do: :ssh_file.encode([{key, [hostnames: [String.to_charlist(host)]]}], :known_hosts)

  test "matches a hostname entry regardless of case", %{system: system, key: key} do
    File.write!(system, line(key, "Gateway.example.com"))

    assert host_key?(key, "gateway.EXAMPLE.com")
    refute host_key?(key, "gateway.example.com", 2222)
  end

  test "matches an IP entry only when the IP is the host connected to", %{
    system: system,
    key: key
  } do
    File.write!(system, line(key, "10.0.0.5"))

    assert host_key?(key, "10.0.0.5")
    refute host_key?(key, "gateway.example.com")
  end

  test "matches wildcard patterns and honours negation", %{system: system, key: key} do
    File.write!(system, line(key, "*.example.com,!db.example.com,gw?"))

    assert host_key?(key, "app.example.com")
    assert host_key?(key, "gw1")
    refute host_key?(key, "db.example.com")
  end

  test "checks the global known_hosts", %{global: global, key: key} do
    File.write!(global, line(key, "gw") <> line(ed25519(), "db"))

    assert host_key?(key, "gw")

    assert {:error, {:host_key_mismatch, %{file: ^global, line: 2, removable: false}}} =
             host_key?(key, "db")
  end

  test "matches a hashed entry", %{system: system, key: key} do
    salt = :crypto.strong_rand_bytes(20)
    hash = :crypto.mac(:hmac, :sha, salt, "[gw]:2222")
    pattern = "|1|#{Base.encode64(salt)}|#{Base.encode64(hash)}"
    File.write!(system, "# comment\n" <> line(key, pattern))

    assert host_key?(key, "gw", 2222)
  end

  test "fails on a revoked key even when it is also trusted", %{
    system: system,
    voyager: voyager,
    key: key
  } do
    File.write!(system, "@revoked " <> line(key, "*"))
    File.write!(voyager, line(key, "gw"))

    assert host_key?(key, "gw") == {:error, {:host_key_revoked, system}}
  end

  test "describes a different key of the same type the way OpenSSH does", %{
    voyager: voyager,
    key: key
  } do
    File.write!(voyager, line(ed25519(), "other") <> line(ed25519(), "[gw]:2222"))
    fingerprint = to_string(:ssh.hostkey_fingerprint(:sha256, key))

    assert host_key?(key, "GW", 2222) ==
             {:error,
              {:host_key_mismatch,
               %{
                 host: "[gw]:2222",
                 file: voyager,
                 line: 2,
                 key_type: "ED25519",
                 fingerprint: fingerprint,
                 removable: true
               }}}
  end

  test "forget removes the host's entries from Voyager's file only", %{
    system: system,
    voyager: voyager,
    key: key
  } do
    other = line(ed25519(), "db")
    revoked = "@revoked " <> line(ed25519(), "gw")
    File.write!(voyager, line(ed25519(), "gw") <> other <> revoked)
    File.write!(system, line(key, "gw"))

    assert KnownHosts.forget("gw") == :ok

    assert File.read!(voyager) == other <> revoked
    assert File.read!(system) == line(key, "gw")
  end

  test "forget succeeds when Voyager's file does not exist", %{voyager: voyager} do
    assert KnownHosts.forget("gw") == :ok
    refute File.exists?(voyager)
  end

  test "forget fails when Voyager's file can't be written", %{voyager: voyager} do
    File.write!(voyager, line(ed25519(), "gw"))
    File.chmod!(voyager, 0o400)
    on_exit(fn -> File.chmod(voyager, 0o600) end)

    assert KnownHosts.forget("gw") == {:error, {:known_hosts_unwritable, voyager}}
  end

  test "fails when a known_hosts file can't be read", %{system: system, key: key} do
    File.write!(system, line(key, "gw"))
    File.chmod!(system, 0o000)
    on_exit(fn -> File.chmod(system, 0o600) end)

    assert host_key?(key, "gw") == {:error, {:known_hosts_unreadable, system}}
  end

  test "treats a host known only by another key type as unknown", %{system: system, key: key} do
    rsa = :public_key.generate_key({:rsa, 2048, 65_537}) |> :ssh_file.extract_public_key()
    File.write!(system, line(rsa, "gw"))

    refute host_key?(key, "gw")
  end

  test "pins keys by host name in Voyager's file, not the system one", %{
    system: system,
    voyager: voyager,
    key: key
  } do
    assert :ok = KnownHosts.add_host_key([~c"10.0.0.5", {10, 0, 0, 5}], 2222, key, opts("GW"))

    assert File.read!(voyager) =~ "[gw]:2222 ssh-ed25519 "
    assert host_key?(key, "gw", 2222)
    refute File.exists?(system)
  end
end

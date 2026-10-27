defmodule Voyager.Services.SSH.KnownHostsTest do
  # async: false because the test points HOME, which is read for the system known_hosts, at a tmp dir.
  use ExUnit.Case, async: false

  alias Voyager.Services.SSH.KnownHosts

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    home = System.get_env("HOME")
    System.put_env("HOME", tmp_dir)
    Application.put_env(:voyager, :known_hosts_path, Path.join(tmp_dir, "voyager_known_hosts"))

    on_exit(fn ->
      System.put_env("HOME", home)
      Application.delete_env(:voyager, :known_hosts_path)
    end)

    File.mkdir_p!(Path.join(tmp_dir, ".ssh"))
    %{system: Path.join([tmp_dir, ".ssh", "known_hosts"]), key: ed25519()}
  end

  defp ed25519,
    do: :public_key.generate_key({:namedCurve, :ed25519}) |> :ssh_file.extract_public_key()

  defp host_key?(key, host, port \\ 22) do
    opts = [key_cb_private: [notify: {self(), make_ref()}]]

    KnownHosts.is_host_key(
      key,
      [String.to_charlist(host), {10, 0, 0, 5}],
      port,
      :"ssh-ed25519",
      opts
    )
  end

  defp line(key, host),
    do: :ssh_file.encode([{key, [hostnames: [String.to_charlist(host)]]}], :known_hosts)

  test "matches a plain entry by host name or IP", %{system: system, key: key} do
    File.write!(system, line(key, "Gateway.example.com") <> line(key, "10.0.0.5"))

    assert host_key?(key, "gateway.example.com")
    refute host_key?(key, "gateway.example.com", 2222)
  end

  test "matches a hashed entry", %{system: system, key: key} do
    salt = :crypto.strong_rand_bytes(20)
    hash = :crypto.mac(:hmac, :sha, salt, "[gw]:2222")
    pattern = "|1|#{Base.encode64(salt)}|#{Base.encode64(hash)}"
    File.write!(system, "# comment\n@revoked * ssh-rsa AAAA\n" <> line(key, pattern))

    assert host_key?(key, "gw", 2222)
  end

  test "reports a different key of the same type as a mismatch", %{system: system, key: key} do
    File.write!(system, line(ed25519(), "gw"))

    assert host_key?(key, "gw") == {:error, :host_key_mismatch}
  end

  test "treats a host known only by another key type as unknown", %{system: system, key: key} do
    rsa = :public_key.generate_key({:rsa, 2048, 65_537}) |> :ssh_file.extract_public_key()
    File.write!(system, line(rsa, "gw"))

    refute host_key?(key, "gw")
  end

  test "pins keys in Voyager's file, not the system one", %{system: system, key: key} do
    assert :ok = KnownHosts.add_host_key([~c"gw", {10, 0, 0, 5}], 2222, key, [])

    assert host_key?(key, "gw", 2222)
    refute File.exists?(system)
  end
end

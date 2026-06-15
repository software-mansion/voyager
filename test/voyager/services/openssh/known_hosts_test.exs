defmodule Voyager.Services.OpenSSH.KnownHostsTest do
  use ExUnit.Case, async: false

  alias Voyager.Services.OpenSSH.KnownHosts

  setup do
    tmp = Path.join(System.tmp_dir!(), "voyager_kh_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    file = Path.join(tmp, "known_hosts")
    Application.put_env(:voyager, :known_hosts_path, file)

    on_exit(fn ->
      Application.delete_env(:voyager, :known_hosts_path)
      File.rm_rf!(tmp)
    end)

    {:ok, kh_file: file}
  end

  describe "ensure_file!/0" do
    test "creates the file and parent directory when missing", %{kh_file: file} do
      refute File.exists?(file)
      :ok = KnownHosts.ensure_file!()
      assert File.exists?(file)
    end
  end

  describe "known?/1" do
    test "returns false for unknown host" do
      refute KnownHosts.known?("never.seen.example")
    end

    test "returns true after add/2", %{kh_file: file} do
      raw = sample_keyscan_line("trusted.example")
      KnownHosts.add("trusted.example", raw)

      assert File.read!(file) =~ "trusted.example"
      assert KnownHosts.known?("trusted.example")
    end
  end

  describe "add/2" do
    test "does not duplicate entries when called twice with the same host", %{kh_file: file} do
      raw = sample_keyscan_line("dup.example")
      KnownHosts.add("dup.example", raw)
      KnownHosts.add("dup.example", raw)

      occurrences =
        file |> File.read!() |> String.split("\n") |> Enum.count(&(&1 =~ "dup.example"))

      assert occurrences == 1
    end

    test "appends without clobbering existing entries", %{kh_file: file} do
      KnownHosts.add("one.example", sample_keyscan_line("one.example"))
      KnownHosts.add("two.example", sample_keyscan_line("two.example"))

      contents = File.read!(file)
      assert contents =~ "one.example"
      assert contents =~ "two.example"
    end
  end

  defp sample_keyscan_line(host) do
    """
    #{host} ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    """
  end
end

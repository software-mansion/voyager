defmodule Voyager.Services.OpenSSH.TunnelTest do
  use ExUnit.Case, async: false

  alias Voyager.Services.OpenSSH.Tunnel

  @moduletag capture_log: true

  setup do
    tmp = Path.join(System.tmp_dir!(), "voyager_tun_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:voyager, :known_hosts_path, Path.join(tmp, "known_hosts"))

    on_exit(fn ->
      Application.delete_env(:voyager, :known_hosts_path)
      File.rm_rf!(tmp)
    end)

    :ok
  end

  describe "start_link/1" do
    test "fails fast with :tunnel_not_ready when the SSH host is unreachable" do
      {:ok, free_port} = pick_port()

      result =
        Tunnel.start_link(
          user: "nobody",
          host: "127.0.0.1",
          ssh_port: 1,
          auth: :agent,
          local_port: free_port,
          remote_host: "127.0.0.1",
          remote_port: 4369
        )

      assert {:error, {:tunnel_not_ready, _reason, _stderr}} = result
    end
  end

  describe "stop/1" do
    test "is a no-op for a dead pid" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert :ok = Tunnel.stop(pid)
    end
  end

  defp pick_port do
    {:ok, s} = :gen_tcp.listen(0, active: false)
    {:ok, p} = :inet.port(s)
    :gen_tcp.close(s)
    {:ok, p}
  end
end

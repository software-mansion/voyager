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

  describe "owner / caller lifecycle" do
    test "stops when its monitored owner goes down" do
      owner_ref = make_ref()
      state = %{port: nil, buf: "", local_port: 1234, owner_ref: owner_ref}

      assert {:stop, :normal, ^state} =
               Tunnel.handle_info({:DOWN, owner_ref, :process, self(), :shutdown}, state)
    end

    test "ignores a DOWN that is not from its owner" do
      state = %{port: nil, buf: "", local_port: 1234, owner_ref: make_ref()}

      assert {:noreply, ^state} =
               Tunnel.handle_info({:DOWN, make_ref(), :process, self(), :shutdown}, state)
    end

    test "stops when a linked process (its caller) exits" do
      state = %{port: nil, buf: "", local_port: 1234, owner_ref: nil}

      assert {:stop, :normal, ^state} = Tunnel.handle_info({:EXIT, self(), :crash}, state)
    end

    test "ignores EXIT signals from its own ssh port" do
      port = Port.open({:spawn, "cat"}, [:binary])
      state = %{port: port, buf: "", local_port: 1234, owner_ref: nil}

      assert {:noreply, ^state} = Tunnel.handle_info({:EXIT, port, :normal}, state)

      Port.close(port)
    end
  end

  defp pick_port do
    {:ok, s} = :gen_tcp.listen(0, active: false)
    {:ok, p} = :inet.port(s)
    :gen_tcp.close(s)
    {:ok, p}
  end
end

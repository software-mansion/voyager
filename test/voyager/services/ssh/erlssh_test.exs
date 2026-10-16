defmodule Voyager.Services.SSH.ErlsshTest do
  # async: false because the test points HOME, which :ssh_file reads for known_hosts, at a tmp dir.
  use ExUnit.Case, async: false

  alias Voyager.Services.SSH.Erlssh
  alias Voyager.Test.SshServer

  setup %{tmp_dir: tmp_dir} do
    home = System.get_env("HOME")
    System.put_env("HOME", tmp_dir)
    on_exit(fn -> System.put_env("HOME", home) end)
  end

  describe "keepalive" do
    @describetag :tmp_dir

    setup do
      Application.put_env(:voyager, :ssh_alive, %{interval: 100, count_max: 2})
      on_exit(fn -> Application.delete_env(:voyager, :ssh_alive) end)
    end

    test "closes the connection when the server stops answering" do
      %{port: port} = SshServer.start!({127, 0, 0, 1})
      conn = connect!(port)
      assert_receive {:ssh_server_connection, server_pid}
      ref = Process.monitor(conn)

      :sys.suspend(server_pid)
      assert_receive {:DOWN, ^ref, :process, ^conn, _reason}, 1_000
      :sys.resume(server_pid)
    end

    test "keeps an idle connection open while the server answers" do
      %{port: port} = SshServer.start!({127, 0, 0, 1})
      conn = connect!(port)
      ref = Process.monitor(conn)

      refute_receive {:DOWN, ^ref, :process, ^conn, _reason}, 500
      Erlssh.close(conn)
    end
  end

  defp connect!(port) do
    {:ok, conn} =
      Erlssh.connect("127.0.0.1", port, SshServer.user(), {:password, SshServer.password()})

    conn
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
end

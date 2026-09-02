defmodule Voyager.Epmd.DaemonTest do
  use ExUnit.Case, async: false

  alias Voyager.Epmd.Daemon

  setup do
    assert :ok = Daemon.start()

    on_exit(fn ->
      _ = Daemon.start()
    end)

    :ok
  end

  describe "running?/0" do
    test "returns true when EPMD is running" do
      assert Daemon.running?()
    end

    test "returns false when EPMD is stopped" do
      stop_epmd!()

      refute Daemon.running?()
    end
  end

  describe "start/0" do
    test "returns :ok when EPMD is already running" do
      assert Daemon.running?()
      assert :ok = Daemon.start()
      assert Daemon.running?()
    end

    test "starts EPMD when it is not running" do
      stop_epmd!()

      refute Daemon.running?()

      assert :ok = Daemon.start()
      assert Daemon.running?()
    end
  end

  describe "ensure_running/0" do
    test "returns :ok when EPMD is already running" do
      assert :ok = Daemon.ensure_running()
    end

    test "starts EPMD when it is not running" do
      stop_epmd!()

      refute Daemon.running?()

      assert :ok = Daemon.ensure_running()
      assert Daemon.running?()
    end
  end

  defp stop_epmd! do
    epmd =
      System.find_executable("epmd") ||
        raise "epmd executable not found"

    {output, status} =
      System.cmd(epmd, ["-kill"], stderr_to_stdout: true)

    assert status == 0, "failed to stop epmd: #{output}"

    wait_until(fn -> not Daemon.running?() end)
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(_fun, 0) do
    raise "condition was not satisfied"
  end

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end
end

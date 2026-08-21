defmodule Voyager.Epmd.DaemonTest do
  use ExUnit.Case, async: true

  alias Voyager.Epmd.Daemon

  describe "running?/0" do
    test "returns true when EPMD is running" do
      assert Daemon.running?()
    end
  end

  describe "start/0" do
    test "returns :ok when EPMD is already running (idempotent)" do
      assert :ok = Daemon.start()
    end
  end
end

defmodule Voyager.Services.Distribution.EpmdRecoveryTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.Distribution.EpmdRecovery

  describe "action/3" do
    test "keeps distribution when EPMD was already running" do
      assert EpmdRecovery.action(true, :ok, true) == :keep_distribution
      assert EpmdRecovery.action(true, {:error, :boom}, false) == :keep_distribution
    end

    test "keeps distribution when EPMD was started successfully and is responding" do
      assert EpmdRecovery.action(false, :ok, true) == :keep_distribution
    end

    test "restarts distribution when EPMD cannot be recovered" do
      assert EpmdRecovery.action(false, {:error, :boom}, false) ==
               :restart_distribution
    end

    test "restarts distribution when start succeeded but EPMD is still unavailable" do
      assert EpmdRecovery.action(false, :ok, false) ==
               :restart_distribution
    end
  end
end

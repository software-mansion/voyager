defmodule Voyager.NodeSession.Connectors.DistributionTest do
  use Voyager.DataCase, async: false

  alias Voyager.NodeSession.Connectors.Distribution

  @moduletag capture_log: true

  test "name/0 identifies the connector" do
    assert Distribution.name() == :distribution
  end

  test "subscriptions/0 is empty - a dead distribution session is only signalled via :nodedown" do
    assert Distribution.subscriptions() == []
  end

  test "teardown?/2 is always false" do
    refute Distribution.teardown?(:anything, %{})
    refute Distribution.teardown?({:tunnel_down, self()}, %{})
  end

  describe "connect/3" do
    test "returns an error, not a crash, for an unreachable node" do
      assert {:error, _reason} =
               Distribution.connect("nobody@127.0.0.1", "cookie", name_type: :longnames)
    end
  end

  describe "disconnect/2" do
    test "always returns :ok" do
      assert Distribution.disconnect(:"nobody@127.0.0.1", %{}) == :ok
    end
  end
end

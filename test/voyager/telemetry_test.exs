defmodule Voyager.TelemetryTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Voyager.Telemetry

  describe "dispatch/2" do
    test "executes known event" do
      handler_id = "dispatch-connect-test-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:voyager, :node, :connect],
        fn _event, _measurements, _metadata, _config -> send(parent, :connected) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok = Telemetry.dispatch!("voyager.node.connect")
      assert_receive :connected
    end

    test "passes measurements and metadata" do
      handler_id = "dispatch-connect-test-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:voyager, :node, :connect],
        fn _event, measurements, metadata, _config -> send(parent, {measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok =
               Telemetry.dispatch!("voyager.node.connect",
                 measurements: %{total: 100},
                 metadata: %{metadata: "test"}
               )

      assert_receive {measurements, metadata}
      assert measurements == %{total: 100}
      assert metadata == %{metadata: "test"}
    end

    test "raises an error for unknown event" do
      assert_raise ArgumentError, fn ->
        Telemetry.dispatch!("voyager.unknown.event")
      end
    end
  end
end

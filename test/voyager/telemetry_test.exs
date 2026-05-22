defmodule Voyager.TelemetryTest do
  use ExUnit.Case, async: true

  alias Voyager.Telemetry
  alias Voyager.Telemetry.Events
  alias Voyager.Telemetry.Measurements

  describe "Events.events/1" do
    test "defaults to :all and includes phoenix, system, and custom events" do
      events = Events.events()

      assert [:phoenix, :live_view, :mount, :start] in events
      assert [:voyager, :vm, :memory] in events
      assert [:voyager, :node, :connect] in events
    end

    test "returns events by requested type" do
      assert [:voyager, :vm, :memory] in Events.events(:system)
      assert [:voyager, :node, :connect] in Events.events(:custom)
      assert [:voyager, :node, :disconnect] in Events.events(:custom)
      assert [:phoenix, :live_view, :mount, :start] in Events.events(:phoenix)
    end

    test "phoenix events include all live_view lifecycle events" do
      phoenix_events = Events.events(:phoenix)

      for action <- [:mount, :handle_event, :handle_info],
          phase <- [:start, :stop, :exception] do
        assert [:phoenix, :live_view, action, phase] in phoenix_events
      end
    end
  end

  describe "Events.name_to_list/1" do
    test "translates dotted event name to atom list" do
      assert Events.name_to_list("voyager.vm.memory") == [:voyager, :vm, :memory]
    end

    test "translates phoenix event name" do
      assert Events.name_to_list("phoenix.live_view.mount.start") ==
               [:phoenix, :live_view, :mount, :start]
    end
  end

  describe "Measurements.vm_memory/0" do
    test "returns numeric memory fields" do
      measurements = Measurements.vm_memory()

      assert is_integer(measurements.total)
      assert is_integer(measurements.processes)
      assert measurements.total >= measurements.processes
    end
  end

  describe "Telemetry.emit_vm_memory/0" do
    test "executes voyager.vm.memory telemetry event with memory measurements" do
      handler_id = "vm-memory-test-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:voyager, :vm, :memory],
        fn _event, measurements, _metadata, _config ->
          send(parent, {:memory, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Telemetry.emit_vm_memory()

      assert_receive {:memory, measurements}
      assert Map.has_key?(measurements, :total)
      assert is_integer(measurements.total)
    end
  end

  describe "Telemetry.dispatch/2" do
    test "executes voyager.node.connect event" do
      handler_id = "dispatch-connect-test-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:voyager, :node, :connect],
        fn _event, _measurements, _metadata, _config -> send(parent, :connected) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok = Telemetry.dispatch("voyager.node.connect")
      assert_receive :connected
    end

    test "executes voyager.node.disconnect event" do
      handler_id = "dispatch-disconnect-test-#{System.unique_integer()}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:voyager, :node, :disconnect],
        fn _event, _measurements, _metadata, _config -> send(parent, :disconnected) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok = Telemetry.dispatch("voyager.node.disconnect")
      assert_receive :disconnected
    end

    test "returns error for unknown event" do
      assert {:error, :unknown_event} = Telemetry.dispatch("voyager.unknown.event")
    end
  end
end

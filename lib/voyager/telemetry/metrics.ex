defmodule Voyager.Telemetry.Metrics do
  @moduledoc """
  Telemetry metrics reported to the Phoenix LiveDashboard.
  """

  import Telemetry.Metrics

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # Focused LiveView timings/exceptions only
      summary("phoenix.live_view.mount.stop.duration",
        tags: [:view],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.mount.exception.duration",
        tags: [:view],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_event.stop.duration",
        tags: [:view, :event],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_event.exception.duration",
        tags: [:view, :event],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_info.stop.duration",
        tags: [:view],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_info.exception.duration",
        tags: [:view],
        unit: {:native, :millisecond}
      ),

      # Voyager node connection counters
      counter("voyager.node.connect.count", measurement: fn _measurements, _metadata -> 1 end),
      counter("voyager.node.disconnect.count", measurement: fn _measurements, _metadata -> 1 end),

      # Voyager VM memory statistics
      summary("voyager.vm.memory.total", unit: {:byte, :kilobyte}),
      summary("voyager.vm.memory.processes", unit: {:byte, :kilobyte}),
      summary("voyager.vm.memory.atom", unit: {:byte, :kilobyte}),
      summary("voyager.vm.memory.ets", unit: {:byte, :kilobyte}),
      summary("voyager.vm.memory.binary", unit: {:byte, :kilobyte}),
      summary("voyager.vm.memory.code", unit: {:byte, :kilobyte}),
      summary("voyager.vm.memory.system", unit: {:byte, :kilobyte})
    ]
  end
end

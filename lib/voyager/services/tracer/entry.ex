defmodule Voyager.Services.Tracer.Entry do
  @moduledoc false

  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config

  @spec configured(Tracer.origin(), node(), Config.t()) :: map()
  def configured(origin, node, config), do: build(:configured, origin, node: node, config: config)

  @spec started(Tracer.origin()) :: map()
  def started(origin), do: build(:started, origin)

  @spec stopped(Tracer.origin() | nil, Tracer.stop_reason(), non_neg_integer(), non_neg_integer()) ::
          map()
  def stopped(origin, reason, traces, dropped),
    do: build(:stopped, origin, reason: reason, traces: traces, dropped: dropped)

  @doc "A list so that no drops add no entry to the log."
  @spec dropped(non_neg_integer()) :: [map()]
  def dropped(0), do: []
  def dropped(count), do: [build(:dropped, nil, count: count)]

  @spec trace(map()) :: map()
  def trace(event), do: Map.put(event, :kind, :trace)

  defp build(kind, origin, fields \\ []) do
    Map.merge(%{kind: kind, origin: origin, at: System.os_time(:microsecond)}, Map.new(fields))
  end
end

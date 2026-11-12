defmodule Voyager.Services.Tracer.Entry do
  @moduledoc """
  Builds the entries of a session log: configured, started and stopped controls,
  drop counts and trace events.
  """

  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config

  @type t :: %{
          required(:seq) => non_neg_integer(),
          required(:kind) => :configured | :started | :stopped | :dropped | :trace,
          required(:at) => integer(),
          optional(atom()) => term()
        }

  @type unnumbered :: %{
          required(:kind) => :configured | :started | :stopped | :dropped | :trace,
          required(:at) => integer(),
          optional(atom()) => term()
        }

  @spec configured(Tracer.origin(), node(), Config.t(), Config.t() | nil) :: unnumbered()
  def configured(origin, node, config, previous),
    do: build(:configured, origin, node: node, config: config, previous: previous)

  @spec started(Tracer.origin()) :: unnumbered()
  def started(origin), do: build(:started, origin)

  @spec stopped(Tracer.origin() | nil, Tracer.stop_reason(), non_neg_integer(), non_neg_integer()) ::
          unnumbered()
  def stopped(origin, reason, traces, dropped),
    do: build(:stopped, origin, reason: reason, traces: traces, dropped: dropped)

  @spec dropped(non_neg_integer()) :: [unnumbered()]
  def dropped(0), do: []
  def dropped(count), do: [build(:dropped, nil, count: count)]

  @spec trace(map()) :: unnumbered()
  def trace(event), do: Map.put(event, :kind, :trace)

  defp build(kind, origin, fields \\ []) do
    Map.merge(%{kind: kind, origin: origin, at: System.os_time(:microsecond)}, Map.new(fields))
  end
end

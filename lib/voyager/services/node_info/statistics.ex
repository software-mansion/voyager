defmodule Voyager.Services.NodeInfo.Statistics do
  @moduledoc """
  Coarse runtime counters for a BEAM node.
  Counters are cumulative since node start.
  """

  @statistics_keys [
    :wall_clock,
    :io,
    :reductions
  ]

  @type t :: %__MODULE__{
          uptime_ms: non_neg_integer(),
          io_input_bytes: non_neg_integer(),
          io_output_bytes: non_neg_integer(),
          total_reductions: non_neg_integer()
        }

  @derive JSON.Encoder
  defstruct [
    :uptime_ms,
    :io_input_bytes,
    :io_output_bytes,
    :total_reductions
  ]

  @spec statistics_keys() :: [atom()]
  def statistics_keys, do: @statistics_keys

  @spec build(map()) :: t()
  def build(stat) do
    {wall_clock_total, _} = Map.fetch!(stat, :wall_clock)
    {{:input, io_in}, {:output, io_out}} = Map.fetch!(stat, :io)
    {reductions, _} = Map.fetch!(stat, :reductions)

    %__MODULE__{
      uptime_ms: wall_clock_total,
      io_input_bytes: io_in,
      io_output_bytes: io_out,
      total_reductions: reductions
    }
  end
end

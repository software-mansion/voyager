defmodule Voyager.MCP.Tools.TraceResult do
  @moduledoc """
  Reports the trace requested with `trace_propose` or `trace_request` in this session.

  `status` is `awaiting_approval`, `expired`, `decline`, `cancel`, `failed`, `unavailable`,
  `running` or `stopped`. A running or stopped trace returns its limits, totals and the
  newest `limit` calls, oldest first. Calls are kept in memory only, the newest 500.
  """

  use Anubis.Server.Component, type: :tool

  alias Voyager.MCP.Tracing

  schema do
    field :limit, :integer,
      default: 100,
      min: 1,
      max: 500,
      description: "How many of the newest calls to return."
  end

  @impl true
  def execute(params, frame), do: Tracing.result(frame, params.limit)
end

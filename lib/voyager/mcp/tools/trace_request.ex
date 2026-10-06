defmodule Voyager.MCP.Tools.TraceRequest do
  @moduledoc """
  Asks the user to type the parameters of a function call trace on the connected node:
  which function, what to capture, and when to stop. Use it when the user should decide
  what to trace; use `trace_propose` when you have a concrete proposal.

  Returns at once with `awaiting_approval`. Poll `trace_result` for the outcome and the
  captured calls. Fails with `Busy` while another trace runs.
  """

  use Anubis.Server.Component, type: :tool

  alias Voyager.MCP.Tracing

  schema do
    field :reason, :string,
      required: true,
      description: "One sentence shown to the user: what you are investigating."
  end

  @impl true
  def execute(params, frame) do
    Tracing.ask("An AI agent asks you to set up a trace: #{params.reason}", %{}, frame)
  end
end

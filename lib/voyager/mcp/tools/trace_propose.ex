defmodule Voyager.MCP.Tools.TracePropose do
  @moduledoc """
  Proposes a function call trace on the connected node. The user sees the proposed
  parameters in a form, can change them, and accepts or declines.

  Returns at once with `awaiting_approval`; nothing is traced until the user accepts.
  Poll `trace_result` for the outcome and the captured calls. Only one trace runs at a
  time: this fails with `Busy` while the Voyager UI or another request is tracing.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.MCP.Tracing
  alias Voyager.Services.Tracer

  schema do
    field :function, :string,
      required: true,
      description:
        "`Module.function/arity` (`*` for any arity), e.g. `MyApp.Repo.insert/2` or `:ets.insert/2`."

    field :reason, :string,
      required: true,
      description: "One sentence shown to the user: why this trace helps."

    field :capture, :enum,
      values: ~w(arity args),
      default: "arity",
      description:
        "`arity` sends no argument values; `args` sends arguments (cut to 500 words) to you."

    field :local, :boolean,
      default: false,
      description: "Also trace calls made from inside the same module."

    field :max_events, :integer,
      default: 100,
      min: 1,
      max: 500,
      description: "Stop after this many calls."

    field :duration_s, :integer,
      default: 10,
      min: 1,
      max: 300,
      description: "Stop after this many seconds."

    field :max_rate, :integer,
      default: 1_000,
      min: 1,
      max: 1_000,
      description: "Stop when the function is called more often than this per second."
  end

  @impl true
  def execute(params, frame) do
    case Tracer.parse_function(params.function) do
      {:ok, _function} ->
        defaults = %{
          "function" => params.function,
          "capture" => params.capture,
          "local" => params.local,
          "max_events" => params.max_events,
          "duration_s" => params.duration_s,
          "max_rate" => params.max_rate
        }

        Tracing.ask(
          "An AI agent wants to trace a function on your node: #{params.reason}",
          defaults,
          frame
        )

      :error ->
        {:reply,
         Response.error(
           Response.tool(),
           "`function` must be Module.function/arity, e.g. Enum.map/2"
         ), frame}
    end
  end
end

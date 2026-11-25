defmodule Voyager.MCP.Tools.CreateTraceSession do
  @moduledoc """
  Proposes a tracing session on the connected node. The user reviews it in a
  form and the session starts only once they accept; the result carries its
  `session_id`. A declined or cancelled form returns `declined`, a failed start
  an error. Only one session runs at a time, and the client must support forms
  (MCP elicitation).

  `function` prefills the form: `Mod.fun/arity`, `Mod.fun` (any arity) or `Mod`
  (every function), with Erlang modules as `:mod.fun/arity` or `mod:fun/arity`.
  Examples: "MyApp.Repo.insert/2", "MyApp.Orders.place", ":gen_tcp.send/2".

  The user chooses whether call arguments are captured; captured arguments, and
  return values with `return_trace`, are sent to the AI. `scope` `local` also sees
  calls within a module and private functions, which the default `global` misses.
  `new_processes_only` traces only processes spawned after the start, far cheaper
  than all of them. `save` keeps every event in Voyager's history; an unsaved
  session keeps only its newest #{Voyager.Services.Tracer.kept_traces()} and is replaced by the next one (the form says
  when that discards events). Set at least one limit: `max_events` (1 to 10000),
  `max_seconds` (1 to 3600) or `max_rate` (events per second, 1 to
  1000); the session stops at the first one reached. Calls, returns and
  exceptions each count as one event, so with `return_trace` a call takes
  two. `pids` restricts tracing to those processes ("<0.123.0>, <0.456.0>");
  empty traces all of them.

  Refused modules: #{Enum.map_join(Voyager.Services.Tracer.Refusals.agent_macros()[:TRACE_ALWAYS_REFUSED], ", ", &inspect/1)} and
  Voyager's agent always. On all processes also the modules called from nearly
  every process, which need `pids`:
  #{Enum.map_join(Voyager.Services.Tracer.Refusals.agent_macros()[:TRACE_HOT], ", ", &inspect/1)},
  and modules starting with #{Enum.join(Voyager.Services.Tracer.Refusals.agent_macros()[:TRACE_HOT_PREFIXES], " or ")}.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Frame
  alias Anubis.Server.InputRequired
  alias Anubis.Server.Response
  alias Voyager.MCP.Tools.Remote
  alias Voyager.MCP.Tools.TraceForm
  alias Voyager.MCP.Tools.TraceReport
  alias Voyager.NodeSession
  alias Voyager.Services.Tracer
  alias Voyager.Services.UsedRequestStates

  @form "session"
  # Signed by anubis with a TTL, so an expired or forged answer is refused before `execute/2`.
  @form_state :create_trace_session

  schema do
    field :function, :string,
      description: ~s(Function to trace, e.g. "MyApp.Repo.insert/2". Prefills the form.)

    field :return_trace, :boolean, default: false, description: "Also trace return values."
    field :max_events, :integer, min: 1, max: TraceForm.max_events(), default: 100
    field :max_seconds, :integer, min: 1, max: TraceForm.max_seconds(), default: 60

    field :max_rate, :integer,
      min: 1,
      max: TraceForm.max_rate(),
      description: "Events per second."

    field :pids, :string,
      description: ~s(Comma-separated pids such as "<0.123.0>"; empty traces all processes.)

    field :new_processes_only, :boolean,
      default: false,
      description: "Without `pids`, trace only processes spawned after the start."

    field :scope, :string, description: ~s["global" (default) or "local"; see the description.]
    field :save, :boolean, default: false, description: "Keep every event in Voyager's history."
  end

  @impl true
  def execute(params, frame) do
    reply =
      with {:ok, %{node: node, connected_at: connected_at} = session} <- check_ready(frame),
           :ok <- TraceForm.check_function(params[:function]) do
        case {Frame.request_state(frame), Frame.input_response(frame, @form)} do
          {{@form_state, ^node, ^connected_at, id}, %{"action" => _action} = response} ->
            answer(UsedRequestStates.consume(id), response, params, session)

          _unanswered_or_other_connection ->
            ask(params, session)
        end
      else
        {:error, message} -> Response.error(Response.tool(), message)
      end

    {:reply, reply, frame}
  end

  defp answer(:used, _response, params, session), do: ask(params, session)

  defp answer(:ok, %{"action" => "accept"} = response, _params, session),
    do: start(session.node, response["content"])

  defp answer(:ok, _declined, _params, _session),
    do: Response.json(Response.tool(), %{status: "declined"})

  defp check_ready(frame) do
    session = NodeSession.current()

    cond do
      is_nil(session) ->
        {:error, Remote.not_connected()}

      match?(%{status: :running}, Tracer.active()) ->
        {:error, "A tracing session is already running, call `trace_watch` or `trace_stop` first"}

      not TraceForm.forms?(frame) ->
        {:error, TraceForm.no_forms()}

      true ->
        {:ok, session}
    end
  end

  defp ask(params, %{node: node, connected_at: connected_at}) do
    message =
      "Start this tracing session on #{node}?" <> TraceForm.discard_warning(Tracer.active())

    InputRequired.new()
    |> InputRequired.elicit(@form, message, TraceForm.schema(defaults(params)))
    |> InputRequired.state({@form_state, node, connected_at, System.unique_integer()})
  end

  defp defaults(params) do
    params
    |> Map.take(
      ~w(function return_trace max_events max_seconds max_rate pids new_processes_only scope save)a
    )
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp start(node, content) do
    with {:ok, attrs} <- TraceForm.config_attrs(content),
         {:ok, session} <-
           Tracer.create_and_start(node, attrs, :mcp, save: content["save"] == true) do
      Response.json(Response.tool(), %{
        status: "started",
        session_id: session.id,
        node: node,
        next: "Call `trace_watch` to wait for the session to end and read its report"
      })
    else
      {:error, reason} -> TraceReport.error(reason)
    end
  end
end

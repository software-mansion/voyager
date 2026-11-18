defmodule Voyager.MCP.Tools.TraceConfigure do
  @moduledoc """
  Proposes new parameters for tracing session `session_id`, the active one or a saved
  one from `trace_history`, so it can run again without creating a new session. The
  user reviews them in the `create_trace_session` form, prefilled with the session's
  current config and the arguments given here; nothing changes until they accept, so
  capturing arguments or widening the target still needs their consent. A stopped
  session goes back to idle: call `trace_start` or `trace_watch` to run it. A saved
  session that is not active is loaded, which replaces an unsaved active one (the form
  says when that discards events). Refused while the session runs. The client must
  support forms (MCP elicitation).
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Frame
  alias Anubis.Server.InputRequired
  alias Anubis.Server.Response
  alias Voyager.MCP.Tools.Remote
  alias Voyager.MCP.Tools.TraceForm
  alias Voyager.MCP.Tools.TraceReport
  alias Voyager.MCP.Tools.TraceStart
  alias Voyager.NodeSession
  alias Voyager.Services.Tracer
  alias Voyager.Services.UsedRequestStates

  @form "session"
  # Signed by anubis with a TTL, so an expired or forged answer is refused before `execute/2`.
  @form_state :trace_configure
  @prefilled ~w(function return_trace max_events max_seconds max_rate pids new_processes_only scope)a

  schema do
    field :session_id, :integer,
      required: true,
      description: "Session to change, e.g. the active one or a saved one from `trace_history`."

    field :function, :string, description: ~s(Function to trace, e.g. "MyApp.Repo.insert/2".)
    field :return_trace, :boolean, description: "Also trace return values."
    field :max_events, :integer, min: 1, max: TraceForm.max_events()
    field :max_seconds, :integer, min: 1, max: TraceForm.max_seconds()

    field :max_rate, :integer,
      min: 1,
      max: TraceForm.max_rate(),
      description: "Events per second."

    field :pids, :string, description: ~s(Comma-separated pids such as "<0.123.0>".)

    field :new_processes_only, :boolean,
      description: "Without `pids`, trace only processes spawned after the start."

    field :scope, :string, description: ~s["global" or "local", as in `create_trace_session`.]
  end

  @impl true
  def execute(%{session_id: id} = params, frame) do
    reply =
      with {:ok, %{node: node, connected_at: connected_at}} <- check_ready(frame),
           {:ok, session} <- find(id),
           :ok <- TraceForm.check_function(params[:function]) do
        case {Frame.request_state(frame), Frame.input_response(frame, @form)} do
          {{@form_state, ^node, ^connected_at, ^id, nonce}, %{"action" => _action} = response} ->
            answer(
              UsedRequestStates.consume(nonce),
              response,
              params,
              session,
              {node, connected_at}
            )

          _unanswered_or_other_session ->
            ask(params, session, node, connected_at)
        end
      else
        {:error, message} -> Response.error(Response.tool(), message)
      end

    {:reply, reply, frame}
  end

  defp check_ready(frame) do
    cond do
      is_nil(NodeSession.current()) -> {:error, Remote.not_connected()}
      not TraceForm.forms?(frame) -> {:error, TraceForm.no_forms()}
      true -> {:ok, NodeSession.current()}
    end
  end

  defp find(id) do
    case Tracer.session(id) do
      {:ok, %{status: :running}, _where} -> {:error, TraceReport.start_error(:busy)}
      {:ok, session, _where} -> {:ok, session}
      {:error, :not_found} -> {:error, "No tracing session #{id}"}
    end
  end

  defp ask(params, session, node, connected_at) do
    message =
      "Change tracing session #{session.id} to trace this on #{node}?" <>
        TraceForm.discard_warning(Tracer.active(), session.id)

    InputRequired.new()
    |> InputRequired.elicit(
      @form,
      message,
      TraceForm.schema(defaults(params, session), save?: false)
    )
    |> InputRequired.state({@form_state, node, connected_at, session.id, System.unique_integer()})
  end

  defp defaults(params, session) do
    current = if session.config, do: TraceForm.defaults(session.config), else: %{}

    proposed =
      for {key, value} <- Map.take(params, @prefilled),
          not is_nil(value),
          into: %{},
          do: {Atom.to_string(key), value}

    Map.merge(current, proposed)
  end

  defp answer(:used, _response, params, session, {node, connected_at}),
    do: ask(params, session, node, connected_at)

  defp answer(:ok, %{"action" => "accept"} = response, _params, session, {node, _connected_at}),
    do: configure(session.id, node, response["content"] || %{})

  defp answer(:ok, _declined, _params, _session, _connection),
    do: Response.json(Response.tool(), %{status: "declined"})

  defp configure(id, node, content) do
    with {:ok, attrs} <- TraceForm.config_attrs(content),
         {:ok, _active, notes} <- TraceStart.activate(id),
         {:ok, session} <- Tracer.configure(node, attrs, :mcp, id) do
      TraceReport.reply(
        session,
        Map.put(notes, :next, "Call `trace_start` or `trace_watch` to run it")
      )
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        Response.error(Response.tool(), "Invalid session: #{TraceForm.format_errors(changeset)}")

      {:error, message} when is_binary(message) ->
        Response.error(Response.tool(), message)

      {:error, reason} ->
        Response.error(Response.tool(), TraceReport.start_error(reason))
    end
  end
end

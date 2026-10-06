defmodule Voyager.MCP.Tracing do
  @moduledoc false

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias Voyager.NodeSession
  alias Voyager.Services.Tracer

  @answer_timeout_ms 300_000
  @max_events 500
  @max_duration_s 300
  @max_rate 1_000

  @doc """
  Sends the trace form to the client and returns at once with `awaiting_approval`.

  `defaults` prefill the form; an empty map leaves every required field for the user to type.
  The answer reaches `handle_answer/2` only after this tool call has returned: anubis defers
  client responses while a request is in flight.
  """
  @spec ask(String.t(), map(), Frame.t()) :: {:reply, Response.t(), Frame.t()}
  def ask(message, defaults, frame) do
    with :ok <- ensure_idle(),
         {:ok, session} <- session_pid() do
      schema = form_schema(defaults)

      # anubis' send_elicitation_request/3 targets self(), and a tool runs in a task, not the session.
      send(
        session,
        {:send_elicitation_request, %{"message" => message, "requestedSchema" => schema}, schema,
         @answer_timeout_ms}
      )

      frame =
        Frame.assign(frame, :trace, %{status: :awaiting_approval, asked_at: DateTime.utc_now()})

      reply(
        %{
          status: "awaiting_approval",
          hint: "The user is reviewing the trace in a form. Call trace_result in a few seconds."
        },
        frame
      )
    else
      {:error, message} -> {:reply, Response.error(Response.tool(), message), frame}
    end
  end

  @doc "Starts the trace the user accepted, or records that they declined."
  @spec handle_answer(map(), Frame.t()) :: Frame.t()
  def handle_answer(answer, %Frame{assigns: %{trace: %{status: :awaiting_approval}}} = frame) do
    Frame.assign(frame, :trace, answer_outcome(answer))
  end

  def handle_answer(_stale, frame), do: frame

  @spec result(Frame.t(), pos_integer()) :: {:reply, Response.t(), Frame.t()}
  def result(frame, limit) do
    case frame.assigns[:trace] do
      nil ->
        {:reply,
         Response.error(
           Response.tool(),
           "No trace requested in this session. Call trace_propose or trace_request first."
         ), frame}

      requested ->
        reply(outcome(requested, limit), frame)
    end
  end

  @spec form_schema(map()) :: map()
  def form_schema(defaults) do
    properties = %{
      "function" => %{
        "type" => "string",
        "title" => "Function",
        "description" => "Module.function/arity, e.g. MyApp.Repo.insert/2 or :ets.insert/2",
        "minLength" => 3
      },
      "capture" => %{
        "type" => "string",
        "title" => "Capture",
        "enum" => ["arity", "args"],
        "enumNames" => ["Arity only", "Arguments (sent to the AI)"]
      },
      "local" => %{"type" => "boolean", "title" => "Include local calls", "default" => false},
      "max_events" => %{
        "type" => "integer",
        "title" => "Stop after this many calls",
        "minimum" => 1,
        "maximum" => @max_events
      },
      "duration_s" => %{
        "type" => "integer",
        "title" => "Stop after this many seconds",
        "minimum" => 1,
        "maximum" => @max_duration_s
      },
      "max_rate" => %{
        "type" => "integer",
        "title" => "Stop above this many calls per second",
        "minimum" => 1,
        "maximum" => @max_rate
      }
    }

    %{
      "type" => "object",
      "properties" =>
        Map.new(properties, fn {name, property} ->
          {name, put_default(property, Map.get(defaults, name))}
        end),
      "required" => ["function", "capture", "max_events", "duration_s", "max_rate"]
    }
  end

  defp put_default(property, nil), do: property
  defp put_default(property, value), do: Map.put(property, "default", value)

  defp ensure_idle do
    case {NodeSession.current(), Tracer.current()} do
      {nil, _} ->
        {:error, "Not connected to any node"}

      {_session, {%{status: :running, origin: origin} = trace, _events}} ->
        {:error,
         "Busy: #{Tracer.spec_label(trace.spec)} is being traced from #{origin_name(origin)}. " <>
           "Only one trace runs at a time; try again when it stops."}

      _idle ->
        :ok
    end
  end

  defp origin_name(:ui), do: "the Voyager UI"
  defp origin_name(:mcp), do: "MCP"

  defp session_pid do
    case Process.get(:"$callers") do
      [session | _] -> {:ok, session}
      _ -> {:error, "Tracing tools must run inside an MCP session"}
    end
  end

  defp answer_outcome(%{"action" => "accept", "content" => content}) do
    with {:ok, function} <- Tracer.parse_function(content["function"]),
         %{node: node} <- NodeSession.current(),
         spec =
           Map.merge(function, %{
             capture: capture(content["capture"]),
             local: content["local"] == true
           }),
         {:ok, trace} <- Tracer.start(node, spec, limits: limits(content), origin: :mcp) do
      %{status: :started, trace_id: trace.id}
    else
      :error -> %{status: :failed, reason: "Not a Module.function/arity: #{content["function"]}"}
      nil -> %{status: :failed, reason: "Not connected to any node"}
      {:error, reason} -> %{status: :failed, reason: Tracer.error_message(reason)}
    end
  end

  defp answer_outcome(%{"action" => action}), do: %{status: :declined, action: action}

  defp limits(content) do
    %{
      max_events: content["max_events"],
      max_rate: content["max_rate"],
      max_time_ms: content["duration_s"] * 1_000
    }
  end

  defp capture("args"), do: :args
  defp capture(_arity), do: :arity

  defp outcome(%{status: :awaiting_approval, asked_at: asked_at}, _limit) do
    if DateTime.diff(DateTime.utc_now(), asked_at, :millisecond) > @answer_timeout_ms do
      %{
        status: "expired",
        hint:
          "No answer within #{div(@answer_timeout_ms, 60_000)} min. The client may not support elicitation."
      }
    else
      %{
        status: "awaiting_approval",
        hint: "The user has not answered yet. Call trace_result again shortly."
      }
    end
  end

  defp outcome(%{status: :declined, action: action}, _limit) do
    %{
      status: action,
      hint: "The user did not approve the trace. Ask before proposing another one."
    }
  end

  defp outcome(%{status: :failed, reason: reason}, _limit),
    do: %{status: "failed", reason: reason}

  defp outcome(%{status: :started, trace_id: id}, limit) do
    case Tracer.current() do
      {%{id: ^id} = trace, events} -> trace_payload(trace, events, limit)
      _replaced -> %{status: "unavailable", reason: "A newer trace replaced its results."}
    end
  end

  defp trace_payload(trace, events, limit) do
    shown = events |> Enum.take(limit) |> Enum.reverse()

    %{
      status: Atom.to_string(trace.status),
      summary: Tracer.status_text(trace),
      function: Tracer.spec_label(trace.spec),
      capture: Atom.to_string(trace.spec.capture),
      local: trace.spec.local,
      limits: %{
        max_events: trace.limits.max_events,
        max_rate: trace.limits.max_rate,
        duration_s: div(trace.limits.max_time_ms, 1_000)
      },
      started_at: DateTime.to_iso8601(trace.started_at),
      calls_total: trace.events,
      calls_dropped: trace.dropped,
      calls: Enum.map(shown, &event_json/1)
    }
    |> maybe_hint(trace)
  end

  defp maybe_hint(payload, %{status: :running}),
    do: Map.put(payload, :hint, "Still running. Call trace_result again for newer calls.")

  defp maybe_hint(payload, _stopped), do: payload

  defp event_json(event) do
    %{
      at: event.at |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601(),
      pid: event.pid,
      process: Tracer.process_label(event.process),
      call: Tracer.call_text(event)
    }
  end

  defp reply(payload, frame), do: {:reply, Response.json(Response.tool(), payload), frame}
end

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

  The user chooses whether call arguments are captured; captured arguments are
  sent to the AI. Set at least one limit: `max_events` (1 to 10000),
  `max_seconds` (1 to 3600) or `max_rate` (events per second, 1 to
  1000); the session stops at the first one reached. Calls, returns and
  exceptions each count as one event, so with `return_trace` a call takes two. `pids` restricts
  tracing to those processes ("<0.123.0>, <0.456.0>"); empty traces all of them.

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
  alias Anubis.Server.Stateless
  alias Voyager.NodeSession
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config

  @max_events 10_000
  @max_seconds 3_600
  @max_rate 1_000
  @form "session"
  # Signed by anubis with a TTL, so an expired or forged answer is refused before `execute/2`.
  @form_state :create_trace_session
  @function_format ~s(`function` must look like "MyApp.Repo.insert/2", "MyApp.Repo" or ":lists.map/2")

  @elixir_mfa ~r/^((?:[A-Z]\w*\.)*[A-Z]\w*)(?:\.([a-z_]\w*[?!]?))?(?:\/(\d+|_))?$/
  @erlang_mfa ~r/^:?([a-z]\w*)(?:[:.]([a-z_]\w*))?(?:\/(\d+|_))?$/

  schema do
    field :function, :string,
      description: ~s(Function to trace, e.g. "MyApp.Repo.insert/2". Prefills the form.)

    field :return_trace, :boolean, default: false, description: "Also trace return values."
    field :max_events, :integer, min: 1, max: @max_events, default: 100
    field :max_seconds, :integer, min: 1, max: @max_seconds, default: 60
    field :max_rate, :integer, min: 1, max: @max_rate, description: "Events per second."

    field :pids, :string,
      description: ~s(Comma-separated pids such as "<0.123.0>"; empty traces all processes.)
  end

  @impl true
  def execute(params, frame) do
    reply =
      with {:ok, node} <- check_ready(frame),
           :ok <- check_function(params[:function]) do
        case {Frame.request_state(frame), Frame.input_response(frame, @form)} do
          {{@form_state, ^node}, %{"action" => "accept", "content" => content}} ->
            start(node, content)

          {{@form_state, _node}, %{"action" => action}} when action != "accept" ->
            Response.json(Response.tool(), %{status: "declined"})

          _unanswered_or_other_node ->
            ask(params, node)
        end
      else
        {:error, message} -> Response.error(Response.tool(), message)
      end

    {:reply, reply, frame}
  end

  defp check_ready(frame) do
    session = NodeSession.current()

    cond do
      is_nil(session) ->
        {:error, "Not connected to any node, call `list_connections` then `connect`"}

      match?(%{status: :running}, Tracer.active()) ->
        {:error, "A tracing session is already running, the user must stop it in Voyager first"}

      not forms?(frame) ->
        {:error,
         "This MCP client does not support forms (elicitation), so it cannot start a session"}

      true ->
        {:ok, session.node}
    end
  end

  # Only stateless-era requests (MCP 2026-07-28) can carry the form within the same tool call.
  defp forms?(%Frame{context: context}) do
    elicitation = Map.get(context.client_capabilities || %{}, "elicitation")

    Stateless.era(context.protocol_module) == :stateless and
      (elicitation == %{} or is_map(elicitation["form"]))
  end

  defp check_function(nil), do: :ok

  defp check_function(function),
    do: if(parse_function(function), do: :ok, else: {:error, @function_format})

  defp ask(params, node) do
    InputRequired.new()
    |> InputRequired.elicit(@form, "Start this tracing session on #{node}?", form_schema(params))
    |> InputRequired.state({@form_state, node})
  end

  defp form_schema(params) do
    %{
      "type" => "object",
      "properties" => %{
        "function" =>
          property("string", params[:function], %{
            "title" => "Function",
            "description" => "Mod.fun/arity, Mod.fun, Mod, or :erlang_mod.fun/arity"
          }),
        "capture_args" =>
          property("boolean", false, %{
            "title" => "Capture arguments",
            "description" => "Call arguments are sent to the AI"
          }),
        "return_trace" =>
          property("boolean", params[:return_trace], %{"title" => "Trace return values"}),
        "max_events" =>
          limit(
            params[:max_events],
            @max_events,
            "Stop after this many events (calls, returns, exceptions)"
          ),
        "max_seconds" =>
          limit(params[:max_seconds], @max_seconds, "Stop after this many seconds"),
        "max_rate" =>
          limit(params[:max_rate], @max_rate, "Stop above this many events per second"),
        "pids" =>
          property("string", params[:pids], %{
            "title" => "Processes",
            "description" => "Comma-separated pids like <0.123.0>; empty traces all processes"
          })
      },
      "required" => ["function"]
    }
  end

  defp limit(default, max, title),
    do: property("integer", default, %{"title" => title, "minimum" => 1, "maximum" => max})

  defp property(type, nil, fields), do: Map.put(fields, "type", type)

  defp property(type, default, fields),
    do: Map.merge(fields, %{"type" => type, "default" => default})

  defp start(node, content) do
    with {:ok, attrs} <- config_attrs(content),
         {:ok, _config} <- validate(attrs),
         {:ok, session} <- Tracer.create_and_start(node, attrs, :mcp) do
      Response.json(Response.tool(), %{status: "started", session_id: session.id, node: node})
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        Response.error(Response.tool(), "Invalid session: #{format_errors(changeset)}")

      {:error, :busy} ->
        Response.error(Response.tool(), "A tracing session is already running")

      {:error, message} when is_binary(message) ->
        Response.error(Response.tool(), message)

      {:error, reason} ->
        message = "Could not trace #{inspect(content["function"])} on #{node}: #{inspect(reason)}"
        Response.error(Response.tool(), message)
    end
  end

  defp config_attrs(content) do
    case parse_function(content["function"]) do
      nil ->
        {:error, @function_format}

      mfa ->
        {:ok,
         mfa
         |> Map.merge(processes(content["pids"]))
         |> Map.merge(%{
           "capture" => if(content["capture_args"] == true, do: "args", else: "arity"),
           "return_trace" => content["return_trace"] == true,
           "max_events" => content["max_events"],
           "max_rate" => content["max_rate"],
           "max_time_ms" => to_ms(content["max_seconds"])
         })}
    end
  end

  defp validate(attrs) do
    attrs
    |> Config.changeset()
    |> Ecto.Changeset.validate_number(:max_events, less_than_or_equal_to: @max_events)
    |> Ecto.Changeset.validate_number(:max_rate, less_than_or_equal_to: @max_rate)
    |> Ecto.Changeset.apply_action(:validate)
  end

  defp to_ms(seconds) when is_integer(seconds), do: seconds * 1_000

  defp to_ms(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {seconds, ""} -> seconds * 1_000
      _invalid -> seconds
    end
  end

  defp to_ms(other), do: other

  defp processes(pids) when is_binary(pids) do
    case pids |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> %{"processes" => "all"}
      pids -> %{"processes" => "pids", "pids" => pids}
    end
  end

  defp processes(_none), do: %{"processes" => "all"}

  defp parse_function(function) when is_binary(function) do
    function = String.trim(function)

    cond do
      match = Regex.run(@elixir_mfa, function, capture: :all_but_first) ->
        [module | rest] = match
        mfa_attrs(["Elixir." <> module | rest])

      match = Regex.run(@erlang_mfa, function, capture: :all_but_first) ->
        mfa_attrs(match)

      true ->
        nil
    end
  end

  defp parse_function(_function), do: nil

  # `Regex.run/3` drops unmatched trailing groups and returns "" for unmatched inner ones.
  defp mfa_attrs([module | rest]) do
    [function, arity] = Enum.take(rest ++ ["", ""], 2)

    %{
      "module" => module,
      "function" => if(function == "", do: "_", else: function),
      "arity" => if(arity in ["", "_"], do: nil, else: String.to_integer(arity))
    }
  end

  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r/%\{(\w+)\}/, message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end
end

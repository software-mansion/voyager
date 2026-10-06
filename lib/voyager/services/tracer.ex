defmodule Voyager.Services.Tracer do
  @moduledoc """
  Runs at most one trace at a time and collects its events.

  The tracer on the remote node pushes event batches straight to this process.
  Events are kept in memory only (the newest 500) and broadcast on `topic/0`
  as `{:trace_events, trace, events}` and `{:trace_status, trace}`.
  """

  use GenServer

  alias Voyager.Agent

  @topic "tracing"
  @limits %{max_events: 10_000, max_rate: 1_000, max_time_ms: 60_000, budget: 500}
  @kept_events 500
  @max_mailbox 1_000
  @start_timeout 6_000
  @function_pattern ~r/^(?<module>:?[A-Za-z_][\w.]*)\.(?<function>[a-z_]\w*[?!]?)\/(?<arity>\d{1,3}|\*)$/

  @type spec :: %{
          module: String.t(),
          function: String.t(),
          arity: non_neg_integer() | :any,
          capture: :arity | :args,
          local: boolean()
        }

  @type trace :: %{
          id: pos_integer(),
          node: node(),
          spec: spec(),
          tracer: pid(),
          origin: :ui | :mcp,
          limits: map(),
          status: :running | :stopped,
          reason: term(),
          events: non_neg_integer(),
          dropped: non_neg_integer(),
          started_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec limits() :: map()
  def limits, do: @limits

  @doc """
  Starts a trace on `node`; `{:error, :busy}` while another one runs.

  Options: `:limits` overrides entries of `limits/0`, `:origin` is `:ui` (default) or `:mcp`.
  """
  @spec start(node(), spec(), keyword()) :: {:ok, trace()} | {:error, term()}
  def start(node, spec, opts \\ []) do
    limits = Map.merge(@limits, Keyword.get(opts, :limits, %{}))
    origin = Keyword.get(opts, :origin, :ui)
    GenServer.call(__MODULE__, {:start, node, spec, limits, origin}, @start_timeout + 1_000)
  end

  @spec stop() :: :ok
  def stop, do: GenServer.call(__MODULE__, :stop)

  @doc "The current or last trace and its kept events, newest first."
  @spec current() :: {trace() | nil, [map()]}
  def current, do: GenServer.call(__MODULE__, :current)

  @doc """
  Parses `Module.function/arity` (Elixir) or `:module.function/arity` (Erlang); `*` is
  any arity. Names stay binaries: the agent only maps them to atoms that already exist.
  """
  @spec parse_function(String.t()) ::
          {:ok, %{module: String.t(), function: String.t(), arity: non_neg_integer() | :any}}
          | :error
  def parse_function(text) when is_binary(text) do
    case Regex.named_captures(@function_pattern, String.trim(text)) do
      %{"module" => module, "function" => function, "arity" => arity} ->
        {:ok, %{module: module_name(module), function: function, arity: parse_arity(arity)}}

      nil ->
        :error
    end
  end

  def parse_function(_text), do: :error

  @spec spec_label(spec()) :: String.t()
  def spec_label(%{module: module, function: function, arity: arity}) do
    display_module =
      case module do
        "Elixir." <> elixir_module -> elixir_module
        erlang_module -> ":" <> erlang_module
      end

    "#{display_module}.#{function}/#{if arity == :any, do: "*", else: arity}"
  end

  @spec call_text(map()) :: String.t()
  def call_text(%{mfa: {module, function, _arity}, args: args, truncated: truncated}) do
    Exception.format_mfa(module, function, args) <> if(truncated, do: " …", else: "")
  end

  def call_text(%{mfa: {module, function, arity}}),
    do: Exception.format_mfa(module, function, arity)

  @doc "A traced process' registered name or initial call, `\"\"` when unknown."
  @spec process_label(term()) :: String.t()
  def process_label({module, function, arity}), do: Exception.format_mfa(module, function, arity)
  def process_label(name) when is_atom(name) and name != :undefined, do: inspect(name)
  def process_label(_none), do: ""

  @spec status_text(trace()) :: String.t()
  def status_text(%{status: :running}), do: "Running"

  def status_text(%{reason: :event_limit, limits: limits}),
    do: "Stopped at #{limits.max_events} events"

  def status_text(%{reason: :rate_limit, limits: limits}),
    do: "Stopped: over #{limits.max_rate} events/s"

  def status_text(%{reason: :time_limit, limits: limits}),
    do: "Stopped after #{div(limits.max_time_ms, 1000)} s"

  def status_text(%{reason: :mailbox_limit}), do: "Stopped: tracer mailbox full"
  def status_text(%{reason: :stopped}), do: "Stopped"
  def status_text(%{reason: {:tracer_down, :noconnection}}), do: "Stopped: node disconnected"
  def status_text(%{reason: reason}), do: "Stopped: #{inspect(reason)}"

  @spec error_message(term()) :: String.t()
  def error_message(:busy), do: "A trace is already running."

  def error_message({:refused, module}),
    do:
      "Tracing #{inspect(module)} on all processes is refused: it is called from almost everywhere."

  def error_message({:not_loaded, module}), do: "#{inspect(module)} is not loaded on the node."
  def error_message(:unknown_function), do: "No such module or function on the node."
  def error_message(:no_function_matched), do: "No function matches that name and arity."
  def error_message(reason), do: "Could not start the trace: #{inspect(reason)}"

  defp module_name(":" <> erlang_module), do: erlang_module
  defp module_name(<<first, _::binary>> = module) when first in ?a..?z, do: module
  defp module_name(module), do: "Elixir." <> module

  defp parse_arity("*"), do: :any
  defp parse_arity(arity), do: String.to_integer(arity)

  @impl true
  def init(nil), do: {:ok, %{trace: nil, events: [], dropped_here: 0}}

  @impl true
  def handle_call(
        {:start, _node, _spec, _limits, _origin},
        _from,
        %{trace: %{status: :running}} = state
      ) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:start, node, spec, limits, origin}, _from, state) do
    case Agent.call(node, :trace_start, [self(), spec, limits], @start_timeout) do
      {:ok, {:ok, tracer}} ->
        Process.monitor(tracer)

        trace = %{
          id: System.unique_integer([:positive]),
          node: node,
          spec: spec,
          tracer: tracer,
          origin: origin,
          limits: limits,
          status: :running,
          reason: nil,
          events: 0,
          dropped: 0,
          started_at: DateTime.utc_now()
        }

        broadcast({:trace_status, trace})
        {:reply, {:ok, trace}, %{state | trace: trace, events: [], dropped_here: 0}}

      {:ok, {:error, reason}} ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stop, _from, %{trace: %{status: :running, tracer: tracer}} = state) do
    send(tracer, :voyager_trace_stop)
    {:reply, :ok, state}
  end

  def handle_call(:stop, _from, state), do: {:reply, :ok, state}

  def handle_call(:current, _from, state), do: {:reply, {state.trace, state.events}, state}

  @impl true
  def handle_info(
        {:voyager_trace_events, tracer, events, dropped},
        %{trace: %{tracer: tracer} = trace} = state
      ) do
    if overloaded?() do
      dropped_here = state.dropped_here + length(events)
      trace = %{trace | dropped: dropped + dropped_here}
      {:noreply, %{state | trace: trace, dropped_here: dropped_here}}
    else
      events = Enum.with_index(events, fn event, i -> Map.put(event, :id, trace.events + i) end)

      trace = %{
        trace
        | events: trace.events + length(events),
          dropped: dropped + state.dropped_here
      }

      broadcast({:trace_events, trace, events})

      kept = Enum.take(Enum.reverse(events) ++ state.events, @kept_events)
      {:noreply, %{state | trace: trace, events: kept}}
    end
  end

  def handle_info(
        {:voyager_trace_done, tracer, reason, %{dropped: dropped}},
        %{trace: %{tracer: tracer}} = state
      ) do
    {:noreply, finish(state, reason, dropped + state.dropped_here)}
  end

  def handle_info(
        {:DOWN, _ref, :process, tracer, reason},
        %{trace: %{tracer: tracer, status: :running} = trace} = state
      ) do
    {:noreply, finish(state, {:tracer_down, reason}, trace.dropped)}
  end

  def handle_info(_stale, state), do: {:noreply, state}

  defp finish(state, reason, dropped) do
    trace = %{state.trace | status: :stopped, reason: reason, dropped: dropped}
    broadcast({:trace_status, trace})
    %{state | trace: trace}
  end

  # Batches are dropped here too, so a flood cannot grow this process' mailbox either.
  defp overloaded? do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    len > @max_mailbox
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Voyager.PubSub, @topic, message)
end

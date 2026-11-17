defmodule Voyager.Services.Tracer.Run do
  @moduledoc false

  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.CallPairing
  alias Voyager.Services.Tracer.Entry
  alias Voyager.Services.Tracer.Session

  # `dropped_before` is the session's count when the run began, `shed` the events dropped here
  # rather than by the agent, and `dropped_logged` the session total covered by `:dropped` entries.
  @enforce_keys [:origin, :dropped_before, :dropped_logged, :started_ms]
  defstruct [
    :origin,
    :dropped_before,
    :dropped_logged,
    :started_ms,
    shed: 0,
    pairing: %CallPairing{},
    stop_request: nil
  ]

  @type t :: %__MODULE__{
          origin: Tracer.origin(),
          dropped_before: non_neg_integer(),
          dropped_logged: non_neg_integer(),
          started_ms: integer(),
          shed: non_neg_integer(),
          pairing: CallPairing.t(),
          stop_request: {Tracer.stop_reason(), Tracer.origin() | nil} | nil
        }

  @spec new(Session.t(), Tracer.origin()) :: t()
  def new(%Session{} = session, origin) do
    %__MODULE__{
      origin: origin,
      dropped_before: session.dropped,
      dropped_logged: session.dropped,
      started_ms: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Accounts for a batch from the remote tracer: sheds it when `shedding?`, pairs returns with
  their calls and updates the session's counts. Returns the entries to log, the session and
  the run.
  """
  @spec absorb(t(), Session.t(), [map()], non_neg_integer(), boolean()) ::
          {[Entry.unnumbered()], Session.t(), t()}
  def absorb(%__MODULE__{} = run, %Session{} = session, events, agent_dropped, shedding?) do
    {events, run} = shed(run, events, shedding?)
    dropped = total_dropped(run, agent_dropped)
    {events, run} = pair_returns(run, session, events, dropped)
    session = %{session | traces: session.traces + length(events), dropped: dropped}
    {dropped_entries, run} = log_drops(run, dropped, shedding?)

    {dropped_entries ++ Enum.map(events, &Entry.trace/1), session, run}
  end

  @doc "The session's drops so far, given the `agent_dropped` count the agent reports for this run."
  @spec total_dropped(t(), non_neg_integer()) :: non_neg_integer()
  def total_dropped(%__MODULE__{} = run, agent_dropped),
    do: run.dropped_before + agent_dropped + run.shed

  defp shed(run, events, true), do: {[], %{run | shed: run.shed + length(events)}}
  defp shed(run, events, false), do: {events, run}

  defp pair_returns(run, session, events, dropped) do
    pairing = if dropped > session.dropped, do: %CallPairing{}, else: run.pairing

    {events, pairing} =
      if session.config.return_trace,
        do: CallPairing.pair(pairing, events),
        else: {events, pairing}

    {events, %{run | pairing: pairing}}
  end

  # While shedding, drops are only counted: a marker per batch would queue on the overloaded Writer.
  defp log_drops(run, _dropped, true), do: {[], run}

  defp log_drops(run, dropped, false),
    do: {Entry.dropped(dropped - run.dropped_logged), %{run | dropped_logged: dropped}}
end

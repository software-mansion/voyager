defmodule Voyager.Services.Tracer.Run do
  @moduledoc false

  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.CallPairing
  alias Voyager.Services.Tracer.Session

  @enforce_keys [:origin, :traces_before, :dropped_before, :dropped_logged, :started_ms]
  defstruct [
    :origin,
    :traces_before,
    :dropped_before,
    :dropped_logged,
    :started_ms,
    shed: 0,
    pairing: %CallPairing{},
    stop_request: nil
  ]

  @type t :: %__MODULE__{
          origin: Tracer.origin(),
          traces_before: non_neg_integer(),
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
      traces_before: session.traces,
      dropped_before: session.dropped,
      dropped_logged: session.dropped,
      started_ms: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Accounts for a batch from the remote tracer: sheds it when `shedding?`, pairs returns with
  their calls and updates the session's counts. Returns the events to log, how many drops
  have not been logged yet, the session and the run.
  """
  @spec absorb(t(), Session.t(), [map()], non_neg_integer(), boolean()) ::
          {[map()], non_neg_integer(), Session.t(), t()}
  def absorb(%__MODULE__{} = run, %Session{} = session, events, agent_dropped, shedding?) do
    {events, shed} =
      if shedding?,
        do: {[], run.shed + length(events)},
        else: {events, run.shed}

    dropped = run.dropped_before + agent_dropped + shed

    pairing = if dropped > session.dropped, do: %CallPairing{}, else: run.pairing

    {events, pairing} =
      if session.config.return_trace,
        do: CallPairing.pair(pairing, events),
        else: {events, pairing}

    session = %{session | traces: session.traces + length(events), dropped: dropped}

    # While shedding, drops are only counted: a marker per batch would queue on the overloaded Writer.
    {unlogged, dropped_logged} =
      if shedding?,
        do: {0, run.dropped_logged},
        else: {dropped - run.dropped_logged, dropped}

    run = %{run | shed: shed, pairing: pairing, dropped_logged: dropped_logged}

    {events, unlogged, session, run}
  end
end

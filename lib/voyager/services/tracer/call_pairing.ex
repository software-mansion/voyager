defmodule Voyager.Services.Tracer.CallPairing do
  @moduledoc """
  Matches return and exception trace events to their calls to time them.
  """

  alias Voyager.Services.Tracer.Entry

  # Returns that never come would grow the open calls forever, so they reset past this.
  @max_open_calls 10_000
  # A straight recursion as deep as `pair/2` times puts a call's outcome this many events away.
  @walk_limit 2 * @max_open_calls

  defstruct open: %{}, count: 0

  @type t :: %__MODULE__{
          open: %{{pid(), mfa()} => [integer()]},
          count: non_neg_integer()
        }

  @type call :: %{call_event: Entry.t() | nil, outcome: Entry.t() | nil}

  @doc """
  Gives each return or exception event the `duration_us` of its call, matched per
  `{pid, mfa}` last in, first out. Unmatched returns pass through unchanged.
  """
  @spec pair(t(), [map()]) :: {[map()], t()}
  def pair(%__MODULE__{} = pairing, events) do
    pairing = if pairing.count > @max_open_calls, do: %__MODULE__{}, else: pairing
    Enum.map_reduce(events, pairing, &pair_event/2)
  end

  @doc "How many candidates are worth reading from a log for `partner/2`."
  @spec walk_limit() :: pos_integer()
  def walk_limit, do: @walk_limit

  @doc """
  The call `event` belongs to, as its call event and outcome, replaying `pair/2` over `side`: the
  trace events on the partner's side of the log, nearest first (later ones for a call event,
  earlier ones for an outcome). A partner is nil when it is not in `side` or was not the one
  `pair/2` timed the outcome with.
  """
  @spec find_call(Entry.t(), [Entry.t()]) :: call()
  def find_call(%{pid: pid, mfa: mfa} = event, side) do
    {own, other} = if call?(event), do: {:call_event, :outcome}, else: {:outcome, :call_event}
    candidates = Enum.filter(side, &match?(%{pid: ^pid, mfa: ^mfa}, &1))
    found = %{own => event, other => partner(event, candidates)}

    # The replay cannot see where pairing restarted after a drop; the outcome's duration can.
    if paired?(found.call_event, found.outcome), do: found, else: %{found | other => nil}
  end

  @doc """
  The one of `candidates` that `pair/2` matched `event` with, replayed from their `type` alone;
  nil when none is. They are the trace events of `event`'s pid and MFA on its partner's side of
  the log, nearest first.
  """
  @spec partner(Entry.t(), [candidate]) :: candidate | nil
        when candidate: %{required(:type) => atom(), optional(atom()) => term()}
  def partner(event, candidates) do
    candidates
    |> Enum.reduce_while(1, fn candidate, open ->
      open = if call?(candidate) == call?(event), do: open + 1, else: open - 1
      if open == 0, do: {:halt, candidate}, else: {:cont, open}
    end)
    |> case do
      %{} = found -> found
      _open -> nil
    end
  end

  @doc "Whether `pair/2` timed `outcome` with `call_event`: same pid and MFA, and its duration ends there."
  @spec paired?(Entry.t() | nil, Entry.t() | nil) :: boolean()
  def paired?(%{pid: pid, mfa: mfa, at: at}, %{
        pid: pid,
        mfa: mfa,
        at: ended,
        duration_us: duration
      }),
      do: ended - duration == at

  def paired?(_call_event, _outcome), do: false

  defp call?(event), do: event.type == :call

  defp pair_event(%{type: :call} = event, pairing), do: {event, open_call(pairing, event)}

  defp pair_event(event, pairing) do
    case close_call(pairing, event) do
      {at, pairing} -> {Map.put(event, :duration_us, event.at - at), pairing}
      nil -> {event, pairing}
    end
  end

  defp open_call(pairing, event) do
    open = Map.update(pairing.open, {event.pid, event.mfa}, [event.at], &[event.at | &1])
    %{pairing | open: open, count: pairing.count + 1}
  end

  defp close_call(pairing, event) do
    key = {event.pid, event.mfa}

    case pairing.open do
      %{^key => [at]} -> {at, closed(pairing, Map.delete(pairing.open, key))}
      %{^key => [at | rest]} -> {at, closed(pairing, Map.put(pairing.open, key, rest))}
      _no_call -> nil
    end
  end

  defp closed(pairing, open), do: %{pairing | open: open, count: pairing.count - 1}
end

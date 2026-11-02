defmodule Voyager.Services.Tracer.CallPairing do
  @moduledoc false

  # Returns that never come would grow the open calls forever, so they reset past this.
  @max_open_calls 10_000

  defstruct open: %{}, count: 0

  @type t :: %__MODULE__{
          open: %{{pid(), mfa()} => [integer()]},
          count: non_neg_integer()
        }

  @doc """
  Gives each return or exception event the `duration_us` of its call, matched per
  `{pid, mfa}` last in, first out. Unmatched returns pass through unchanged.
  """
  @spec pair(t(), [map()]) :: {[map()], t()}
  def pair(%__MODULE__{} = pairing, events) do
    pairing = if pairing.count > @max_open_calls, do: %__MODULE__{}, else: pairing
    Enum.map_reduce(events, pairing, &pair_event/2)
  end

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

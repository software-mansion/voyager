defmodule Voyager.JSONEncoders do
  @moduledoc """
  App-wide `JSON.Encoder` implementations for native Erlang terms that have no
  default JSON representation.

  The implementations are **global**: every `PID`, `Tuple`, `Reference`, `Port`
  and function encoded through `JSON.encode!/1` anywhere in the app uses them,
  and tuples are encoded as JSON arrays rather than raising.

  These are the only types the protocol can reach. `JSON.protocol_encode/2`
  resolves lists, binaries and plain maps before dispatch, and `JSON.Encoder`
  declares no `@fallback_to_any`, so charlists, invalid UTF-8, improper lists
  and foreign structs are sanitised before encoding instead.
  """

  alias JSON.Encoder

  defimpl Encoder, for: PID do
    @spec encode(pid(), JSON.encoder()) :: iodata()
    def encode(pid, encoder), do: encoder.(Voyager.Pid.display(pid), encoder)
  end

  defimpl Encoder, for: Tuple do
    @spec encode(tuple(), JSON.encoder()) :: iodata()
    def encode(tuple, encoder), do: encoder.(Tuple.to_list(tuple), encoder)
  end

  defimpl Encoder, for: [Reference, Port, Function] do
    @spec encode(reference() | port() | fun(), JSON.encoder()) :: iodata()
    def encode(term, encoder), do: encoder.(inspect(term), encoder)
  end
end

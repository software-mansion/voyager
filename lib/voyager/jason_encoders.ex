defmodule Voyager.JasonEncoders do
  @moduledoc """
  App-wide `Jason.Encoder` implementations for native Erlang terms that have no
  default JSON representation.

  These are required so that supervision-tree node values (`name`, `info`) —
  which stay as raw Erlang terms until push time — can be serialised to the
  client. Note the implementations are **global**: every `PID`, `Tuple`,
  `Reference`, and `Port` encoded anywhere in the app uses them. In particular,
  tuples are encoded as JSON arrays rather than raising.
  """

  alias Jason.Encoder

  defimpl Encoder, for: PID do
    @spec encode(pid(), Jason.Encode.opts()) :: iodata()
    def encode(pid, opts) do
      pid
      |> :erlang.pid_to_list()
      |> List.to_string()
      |> Encoder.BitString.encode(opts)
    end
  end

  defimpl Encoder, for: Tuple do
    @spec encode(tuple(), Jason.Encode.opts()) :: iodata()
    def encode(tuple, opts) do
      Jason.Encode.list(Tuple.to_list(tuple), opts)
    end
  end

  defimpl Encoder, for: Reference do
    @spec encode(reference :: reference, options :: Jason.Encode.opts()) :: iodata()
    def encode(reference, opts) do
      reference
      |> inspect
      |> Encoder.BitString.encode(opts)
    end
  end

  defimpl Encoder, for: Port do
    @spec encode(port :: port, options :: Jason.Encode.opts()) :: iodata()
    def encode(port, opts) do
      port
      |> inspect
      |> Encoder.BitString.encode(opts)
    end
  end
end

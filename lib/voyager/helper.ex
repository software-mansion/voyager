defmodule Voyager.Helper do
  @moduledoc false

  alias Jason.Encoder

  defimpl Encoder, for: PID do
    @doc """
    JSON encodes a `PID`.

    Uses `inspect/1` to turn the `pid` into a String and passes the `options` to `Encoder.BitString.encode/1`.
    """
    @spec encode(pid :: pid(), options :: Jason.Encode.opts()) :: iodata()
    def encode(pid, options) do
      pid
      |> inspect()
      |> Encoder.BitString.encode(options)
    end
  end
end

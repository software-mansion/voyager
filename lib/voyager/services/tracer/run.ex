defmodule Voyager.Services.Tracer.Run do
  @moduledoc false

  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.CallPairing

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
end

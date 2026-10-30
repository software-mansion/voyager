defmodule Voyager.Services.Tracer.Run do
  @moduledoc false

  alias Voyager.Services.Tracer

  @enforce_keys [:origin, :traces_before, :dropped_before, :dropped_logged, :started_ms]
  defstruct [
    :origin,
    :traces_before,
    :dropped_before,
    :dropped_logged,
    :started_ms,
    shed: 0,
    open_calls: %{},
    open_count: 0,
    stop_request: nil
  ]

  @type t :: %__MODULE__{
          origin: Tracer.origin(),
          traces_before: non_neg_integer(),
          dropped_before: non_neg_integer(),
          dropped_logged: non_neg_integer(),
          started_ms: integer(),
          shed: non_neg_integer(),
          open_calls: %{{pid(), mfa()} => [integer()]},
          open_count: non_neg_integer(),
          stop_request: {Tracer.stop_reason(), Tracer.origin() | nil} | nil
        }
end

defmodule Voyager.Services.Tracer.Session do
  @moduledoc "The `Voyager.Services.Tracer` session: a node and config, plus the state of its runs. `seq` numbers the next log entry; `started_at` is the first run's start and `stopped_at` the last run's end. A saved session's `id` is its `Voyager.Schemas.TraceSession` row's; an unsaved one's is negative, so the two never collide. `bytes` estimates the saved rows' size, and a run stops once it passes `storage_limit`."

  alias Voyager.Services.Tracer.Config

  @enforce_keys [:id, :origin, :created_at]
  defstruct [
    :id,
    :origin,
    :created_at,
    :node,
    :config,
    :tracer,
    :stop_reason,
    :started_at,
    :stopped_at,
    save: false,
    status: :idle,
    traces: 0,
    dropped: 0,
    bytes: 0,
    storage_limit: 0,
    seq: 0
  ]

  @type t :: %__MODULE__{
          id: integer(),
          origin: Voyager.Services.Tracer.origin(),
          save: boolean(),
          created_at: DateTime.t(),
          node: node() | nil,
          config: Config.t() | nil,
          tracer: pid() | nil,
          status: :idle | :running | :stopped,
          stop_reason: Voyager.Services.Tracer.stop_reason() | String.t() | nil,
          traces: non_neg_integer(),
          dropped: non_neg_integer(),
          bytes: non_neg_integer(),
          storage_limit: non_neg_integer(),
          seq: non_neg_integer(),
          started_at: DateTime.t() | nil,
          stopped_at: DateTime.t() | nil
        }
end

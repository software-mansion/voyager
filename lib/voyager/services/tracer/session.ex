defmodule Voyager.Services.Tracer.Session do
  @moduledoc """
  The `Voyager.Services.Tracer` session: a node and config, plus the state of its runs.

  - `id` is the `Voyager.Schemas.TraceSession` row's when saved; unsaved ids are negative,
    so the two never collide
  - `seq` numbers the next log entry
  - `started_at` is the first run's start and `stopped_at` the last run's end
  - `bytes` estimates the saved rows' size, and a run stops once it passes `storage_limit`
  """

  alias Voyager.Services.Tracer
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
          origin: Tracer.origin(),
          save: boolean(),
          created_at: DateTime.t(),
          node: node() | nil,
          config: Config.t() | nil,
          tracer: pid() | nil,
          status: :idle | :running | :stopped,
          stop_reason: Tracer.stop_reason() | nil,
          traces: non_neg_integer(),
          dropped: non_neg_integer(),
          bytes: non_neg_integer(),
          storage_limit: non_neg_integer(),
          seq: non_neg_integer(),
          started_at: DateTime.t() | nil,
          stopped_at: DateTime.t() | nil
        }

  @spec running(t(), pid(), non_neg_integer()) :: t()
  def running(%__MODULE__{} = session, tracer, storage_limit) do
    %{
      session
      | tracer: tracer,
        status: :running,
        stop_reason: nil,
        started_at: session.started_at || DateTime.utc_now(),
        stopped_at: nil,
        storage_limit: storage_limit
    }
  end

  @spec stopped(t(), Tracer.stop_reason(), non_neg_integer()) :: t()
  def stopped(%__MODULE__{} = session, reason, dropped) do
    %{
      session
      | status: :stopped,
        stop_reason: reason,
        dropped: dropped,
        stopped_at: DateTime.utc_now()
    }
  end

  @doc "A saved session as it was left in `row`; `configured` is its `:configured` entry, or a map with a nil `node` and `config`."
  @spec from_row(
          Voyager.Schemas.TraceSession.t(),
          %{node: node() | nil, config: Config.t() | nil},
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def from_row(row, configured, seq, storage_limit) do
    %__MODULE__{
      id: row.id,
      origin: row.origin,
      save: true,
      created_at: DateTime.from_naive!(row.inserted_at, "Etc/UTC"),
      node: configured.node,
      config: configured.config,
      status: row.status,
      stop_reason: row.stop_reason,
      traces: row.traces,
      dropped: row.dropped,
      bytes: row.bytes,
      storage_limit: storage_limit,
      seq: seq,
      started_at: row.started_at,
      stopped_at: row.stopped_at
    }
  end
end

defmodule Voyager.Services.Tracer.Session do
  @moduledoc """
  The `Voyager.Services.Tracer` session: a node and config, plus the state of its runs.

  - `id` is the `Voyager.Schemas.TraceSession` row's when saved; unsaved ids are negative,
    so the two never collide
  - `seq` numbers the next log entry
  - `started_at` is the first run's start and `stopped_at` the last run's end
  - `run_started_at` is the last run's start and `run_traces_before` the traces of the runs before it
  - `bytes` estimates the saved rows' size, and a run stops once it passes `storage_limit`
  """

  alias Voyager.Schemas.TraceSession
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Entry

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
    :run_started_at,
    save: false,
    status: :idle,
    traces: 0,
    run_traces_before: 0,
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
          run_traces_before: non_neg_integer(),
          dropped: non_neg_integer(),
          bytes: non_neg_integer(),
          storage_limit: non_neg_integer(),
          seq: non_neg_integer(),
          started_at: DateTime.t() | nil,
          stopped_at: DateTime.t() | nil,
          run_started_at: DateTime.t() | nil
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
        run_started_at: DateTime.utc_now(),
        run_traces_before: session.traces,
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

  @doc "The session saved as `row`, from its newest-first control entries."
  @spec from_row(TraceSession.t(), [Entry.t()], non_neg_integer(), non_neg_integer()) :: t()
  def from_row(row, controls, seq, storage_limit) do
    configured = Enum.find(controls, &(&1.kind == :configured)) || %{node: nil, config: nil}
    {run_started_at, run_traces_before} = last_run(row, controls)

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
      run_traces_before: run_traces_before,
      dropped: row.dropped,
      bytes: row.bytes,
      storage_limit: storage_limit,
      seq: seq,
      started_at: row.started_at,
      stopped_at: row.stopped_at,
      run_started_at: run_started_at
    }
  end

  defp last_run(row, controls) do
    case Enum.split_while(controls, &(&1.kind != :started)) do
      {_, []} ->
        {nil, 0}

      {newer, [started | older]} ->
        {DateTime.from_unix!(started.at, :microsecond), traces_before(row, newer, older)}
    end
  end

  # An interrupted run writes no :stopped entry, so only the last run's own count is exact.
  defp traces_before(row, newer, older) do
    case Enum.find(newer, &(&1.kind == :stopped)) do
      %{traces: traces} -> row.traces - traces
      nil -> Enum.sum(for %{kind: :stopped, traces: traces} <- older, do: traces)
    end
  end
end

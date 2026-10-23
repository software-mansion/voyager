defmodule Voyager.Schemas.TraceSession do
  @moduledoc """
  Ecto schema for a saved `Voyager.Services.Tracer.Session`; its log is in
  `Voyager.Schemas.TraceSessionEvent` and `Voyager.Schemas.TraceEvent` rows.
  `bytes` estimates the size of those rows.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: pos_integer() | nil,
          origin: :ui | :mcp | nil,
          status: :idle | :running | :stopped | nil,
          node: String.t() | nil,
          config: map() | nil,
          stop_reason: String.t() | nil,
          traces: non_neg_integer(),
          dropped: non_neg_integer(),
          bytes: non_neg_integer(),
          started_at: DateTime.t() | nil,
          stopped_at: DateTime.t() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "trace_sessions" do
    field :origin, Ecto.Enum, values: [:ui, :mcp]
    field :status, Ecto.Enum, values: [:idle, :running, :stopped]
    field :node, :string
    field :config, :map
    field :stop_reason, :string
    field :traces, :integer, default: 0
    field :dropped, :integer, default: 0
    field :bytes, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :stopped_at, :utc_datetime_usec

    has_many :session_events, Voyager.Schemas.TraceSessionEvent, foreign_key: :session_id
    has_many :events, Voyager.Schemas.TraceEvent, foreign_key: :session_id

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :origin,
      :status,
      :node,
      :config,
      :stop_reason,
      :traces,
      :dropped,
      :bytes,
      :started_at,
      :stopped_at
    ])
    |> validate_required([:origin, :status])
  end
end

defmodule Voyager.Schemas.TraceSessionEvent do
  @moduledoc """
  Ecto schema for what happened to a `Voyager.Schemas.TraceSession`: it was
  configured, started or stopped, or events were dropped. Each kind fills its own
  fields; `dropped` is a `:dropped` event's count and `reason` a `Voyager.StoredTerm.encode/1` binary. Shares `seq` with `Voyager.Schemas.TraceEvent`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: pos_integer() | nil,
          session_id: pos_integer() | nil,
          seq: non_neg_integer() | nil,
          kind: :configured | :started | :stopped | :dropped | nil,
          at: DateTime.t() | nil,
          origin: :ui | :mcp | nil,
          node: String.t() | nil,
          config: map() | nil,
          reason: binary() | nil,
          traces: non_neg_integer() | nil,
          dropped: non_neg_integer() | nil
        }

  schema "trace_session_events" do
    belongs_to :session, Voyager.Schemas.TraceSession
    field :seq, :integer
    field :kind, Ecto.Enum, values: [:configured, :started, :stopped, :dropped]
    field :at, :utc_datetime_usec
    field :origin, Ecto.Enum, values: [:ui, :mcp]
    field :node, :string
    field :config, :map
    field :reason, :binary
    field :traces, :integer
    field :dropped, :integer
  end
end

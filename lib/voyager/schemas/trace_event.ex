defmodule Voyager.Schemas.TraceEvent do
  @moduledoc """
  Ecto schema for a traced call, return or exception of a `Voyager.Schemas.TraceSession`.
  Terms are stored inspected, so `args` and `value` are searchable text.
  Shares `seq` with `Voyager.Schemas.TraceSessionEvent`.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: pos_integer() | nil,
          session_id: pos_integer() | nil,
          seq: non_neg_integer() | nil,
          at: DateTime.t() | nil,
          type: :call | :return | :exception | nil,
          pid: String.t() | nil,
          process: String.t() | nil,
          mfa: String.t() | nil,
          args: String.t() | nil,
          value: String.t() | nil,
          truncated: boolean(),
          duration_us: non_neg_integer() | nil
        }

  schema "trace_events" do
    belongs_to :session, Voyager.Schemas.TraceSession
    field :seq, :integer
    field :at, :utc_datetime_usec
    field :type, Ecto.Enum, values: [:call, :return, :exception]
    field :pid, :string
    field :process, :string
    field :mfa, :string
    field :args, :string
    field :value, :string
    field :truncated, :boolean, default: false
    field :duration_us, :integer
  end
end

defmodule Voyager.Schemas.TraceEvent do
  @moduledoc """
  Ecto schema for a traced call, return or exception of a `Voyager.Schemas.TraceSession`.
  `pid`, `process`, `args` and `value` are `Voyager.StoredTerm.encode/1` binaries, so
  they load back as the traced terms; `search_text` holds them and the MFA inspected, for search.
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
          pid: binary() | nil,
          process: binary() | nil,
          module: String.t() | nil,
          function: String.t() | nil,
          arity: non_neg_integer() | nil,
          args: binary() | nil,
          value: binary() | nil,
          truncated: boolean() | nil,
          duration_us: non_neg_integer() | nil,
          search_text: String.t() | nil
        }

  schema "trace_events" do
    belongs_to :session, Voyager.Schemas.TraceSession
    field :seq, :integer
    field :at, :utc_datetime_usec
    field :type, Ecto.Enum, values: [:call, :return, :exception]
    field :pid, :binary
    field :process, :binary
    field :module, :string
    field :function, :string
    field :arity, :integer
    field :args, :binary
    field :value, :binary
    field :truncated, :boolean
    field :duration_us, :integer
    field :search_text, :string
  end
end

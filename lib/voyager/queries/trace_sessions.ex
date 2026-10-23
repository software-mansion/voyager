defmodule Voyager.Queries.TraceSessions do
  @moduledoc "Read queries for tracing sessions."

  import Ecto.Query
  alias Voyager.Repo
  alias Voyager.Schemas.TraceSession

  @spec all() :: [TraceSession.t()]
  def all do
    TraceSession
    |> order_by([s], desc: s.id)
    |> Repo.all()
  end

  @spec get(integer()) :: TraceSession.t() | nil
  def get(id), do: Repo.get(TraceSession, id)
end

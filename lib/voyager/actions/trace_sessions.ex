defmodule Voyager.Actions.TraceSessions do
  @moduledoc "Write actions for saved tracing sessions."

  import Ecto.Query

  alias Voyager.Queries.TraceSessions, as: TraceSessionQueries
  alias Voyager.Repo
  alias Voyager.Schemas.TraceSession
  alias Voyager.Services.Tracer.Session

  @spec create(map()) :: {:ok, TraceSession.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: %TraceSession{} |> TraceSession.changeset(attrs) |> Repo.insert()

  @doc "Writes the Tracer session's state to its row, adding `stored_bytes` to its `bytes`. Returns the new total."
  @spec sync(Session.t(), non_neg_integer()) :: non_neg_integer()
  def sync(%Session{} = session, stored_bytes) do
    {1, [bytes]} =
      TraceSession
      |> where(id: ^session.id)
      |> select([s], s.bytes)
      |> Repo.update_all(
        set: [
          status: session.status,
          node: session.node && Atom.to_string(session.node),
          config: session.config && Map.from_struct(session.config),
          stop_reason: session.stop_reason,
          traces: session.traces,
          dropped: session.dropped,
          started_at: session.started_at,
          stopped_at: session.stopped_at,
          updated_at: NaiveDateTime.utc_now(:second)
        ],
        inc: [bytes: stored_bytes]
      )

    bytes
  end

  @doc "Deletes the session and its entries."
  @spec delete(integer()) :: {:ok, TraceSession.t()} | {:error, :not_found}
  def delete(id) do
    case TraceSessionQueries.get(id) do
      nil -> {:error, :not_found}
      session -> Repo.delete(session)
    end
  end

  @doc """
  Run on boot: sessions left `running` are stopped with reason `interrupted`,
  since the remote tracer stops when Voyager dies.
  """
  @spec interrupt_running() :: :ok
  def interrupt_running do
    TraceSession
    |> where(status: :running)
    |> Repo.update_all(
      set: [status: :stopped, stop_reason: :interrupted, stopped_at: DateTime.utc_now()]
    )

    :ok
  end
end

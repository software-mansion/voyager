defmodule Voyager.Actions.TraceSessions do
  @moduledoc "Write actions for saved tracing sessions."

  import Ecto.Query

  alias Voyager.Queries.TraceSessions, as: TraceSessionQueries
  alias Voyager.Repo
  alias Voyager.Schemas.TraceSession
  alias Voyager.Services.Tracer.Session

  @spec create(map()) :: {:ok, TraceSession.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs), do: %TraceSession{} |> TraceSession.changeset(attrs) |> Repo.insert()

  @doc "Writes the Tracer session's state to its row."
  @spec sync(Session.t()) :: :ok
  def sync(%Session{} = session) do
    TraceSession
    |> where(id: ^session.id)
    |> Repo.update_all(
      set: [
        status: session.status,
        node: session.node && Atom.to_string(session.node),
        config: session.config && Map.from_struct(session.config),
        stop_reason: stop_reason_text(session.stop_reason),
        traces: session.traces,
        dropped: session.dropped,
        bytes: session.bytes,
        started_at: session.started_at,
        stopped_at: session.stopped_at,
        updated_at: NaiveDateTime.utc_now(:second)
      ]
    )

    :ok
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
  Deletes the oldest sessions with saved entries, never `keep_id`, until their
  `bytes` together with `keep_id`'s fit in `limit`.
  """
  @spec prune(non_neg_integer(), integer()) :: :ok
  def prune(limit, keep_id) do
    kept = Repo.one(from s in TraceSession, where: s.id == ^keep_id, select: s.bytes) || 0

    ids =
      from(s in TraceSession,
        where: s.id != ^keep_id and s.bytes > 0,
        order_by: [desc: s.id],
        select: {s.id, s.bytes}
      )
      |> Repo.all()
      |> Enum.scan({nil, kept}, fn {id, bytes}, {_id, total} -> {id, total + bytes} end)
      |> Enum.filter(fn {_id, total} -> total > limit end)
      |> Enum.map(fn {id, _total} -> id end)

    TraceSession |> where([s], s.id in ^ids) |> Repo.delete_all()
    :ok
  end

  @doc """
  Run on boot: sessions left `running` are stopped with reason `interrupted`,
  since the remote tracer stops when Voyager dies.
  """
  @spec interrupt_running() :: :ok
  def interrupt_running do
    TraceSession
    |> where(status: :running)
    |> Repo.update_all(set: [status: :stopped, stop_reason: "interrupted"])

    :ok
  end

  @doc "How a `Voyager.Services.Tracer.stop_reason()` is stored."
  @spec stop_reason_text(term()) :: String.t() | nil
  def stop_reason_text(nil), do: nil
  def stop_reason_text(reason) when is_binary(reason), do: reason
  def stop_reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  def stop_reason_text(reason), do: inspect(reason)
end

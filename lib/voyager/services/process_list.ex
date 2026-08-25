defmodule Voyager.Services.ProcessList do
  @moduledoc """
  Fetches a bounded "top N processes" list from the connected remote node.

  The scan runs on the remote node inside `:voyager_agent.proc_top/3` (shipped
  via the agent): it walks the process table with an iterator, keeps only the
  running top-`limit` in memory, and is guarded by a `max_heap_size` flag so a
  pathological scan kills the transient worker instead of the node. Only the
  top-`limit` rows cross the wire, minimizing both data transfer and memory
  pressure on the Voyager server.

  All `:erpc` failures are translated to `{:error, reason}` tuples; no raw
  exception escapes to the caller.
  """

  alias Voyager.Erpc
  alias Voyager.NodeSession

  @agent :voyager_agent

  @type entry :: %{required(:pid) => pid(), optional(atom()) => term()}

  @doc """
  Returns the top `limit` processes on the connected node sorted by `sort_by`
  (descending), each carrying the requested `attrs`.

  `sort_by` is always included in the fetched attributes and must resolve to an
  integer on the remote (e.g. `:memory`, `:reductions`, `:message_queue_len`).

  Returns `{:error, :not_connected}` when there is no active session, or
  `{:error, reason}` on remote/transport failure (`:timeout`, `:noconnection`,
  `{:remote_exception, _}`, ...). `timeout` bounds the whole remote scan.
  """
  @spec top([atom()], atom(), pos_integer(), timeout()) :: {:ok, [entry()]} | {:error, term()}
  def top(attrs, sort_by, limit, timeout) do
    case NodeSession.current() do
      %NodeSession.Session{node: node} ->
        call(node, [ensure_sort_by(attrs, sort_by), sort_by, limit], timeout)

      nil ->
        {:error, :not_connected}
    end
  end

  defp ensure_sort_by(attrs, sort_by) do
    if sort_by in attrs, do: attrs, else: [sort_by | attrs]
  end

  # Translates every `:erpc.call` failure into an `{:error, reason}` tuple.
  defp call(node, args, timeout) do
    {:ok, Erpc.call(node, @agent, :proc_top, args, timeout)}
  catch
    :error, {:erpc, :timeout} -> {:error, :timeout}
    :error, {:erpc, :noconnection} -> {:error, :noconnection}
    :error, {:exception, reason, _stack} -> {:error, {:remote_exception, reason}}
    :error, {:erpc, _} = reason -> {:error, reason}
    :error, reason -> {:error, reason}
    :exit, reason -> {:error, {:remote_exit, reason}}
    :throw, value -> {:error, {:remote_throw, value}}
  end
end

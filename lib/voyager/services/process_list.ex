defmodule Voyager.Services.ProcessList do
  @moduledoc """
  Fetches a bounded "top N processes" list from a remote node.

  The scan runs on the remote node inside `:voyager_agent.proc_top/3` (shipped
  via the agent): it walks the process table with an iterator, keeps only the
  running top-`limit` in memory, and is guarded by a `max_heap_size` flag so a
  pathological scan kills the transient worker instead of the node. Only the
  top-`limit` rows cross the wire, minimizing both data transfer and memory
  pressure on the Voyager server.

  The `Voyager.Agent` seam owns the transport and error handling.
  """

  alias Voyager.Agent

  @type entry :: %{required(:pid) => pid(), optional(atom()) => term()}
  @type direction :: :asc | :desc

  @doc """
  Returns the top `limit` processes on `node` sorted by `sort_by`, each carrying
  the requested `attrs`.

  `direction` selects which end to keep and defaults to `:desc` (largest first);
  `:asc` keeps the smallest first. `sort_by` is always included in the fetched
  attributes and must resolve to an integer on the remote (e.g. `:memory`,
  `:reductions`, `:message_queue_len`). `timeout` bounds the whole remote scan.

  Returns `{:ok, entries}` or `{:error, reason}` on remote/transport failure.
  """
  @spec top(node(), [atom()], atom(), pos_integer(), timeout(), direction()) ::
          {:ok, [entry()]} | {:error, term()}
  def top(node, attrs, sort_by, limit, timeout, direction \\ :desc)
      when direction in [:asc, :desc] do
    Agent.call(
      node,
      :proc_top,
      [ensure_sort_by(attrs, sort_by), sort_by, limit, direction],
      timeout
    )
  end

  defp ensure_sort_by(attrs, sort_by) do
    if sort_by in attrs, do: attrs, else: [sort_by | attrs]
  end
end

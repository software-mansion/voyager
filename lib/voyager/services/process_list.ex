defmodule Voyager.Services.ProcessList do
  @moduledoc """
  Fetches a bounded "top N processes" list from a remote node.

  The scan runs on the remote node inside `:voyager_agent.proc_top/4` (shipped
  via the agent): it walks the process table with an iterator, keeps only the
  running top-`limit` in memory, and is guarded by a `max_heap_size` flag so a
  pathological scan kills the transient worker instead of the node. Only the
  top-`limit` rows cross the wire, minimizing both data transfer and memory
  pressure on the Voyager server.

  To keep the scan's per-process cost fixed and its payload independent of
  process state, only the cheap, fixed-size attributes in `allowed_attrs/0` may
  be requested. Unbounded attributes such as `:messages`, `:dictionary`,
  `:backtrace` and `:binary` are rejected — fetching them across the whole table
  would copy each process's mailbox/heap and defeat the bounded-payload
  guarantee.

  The `Voyager.Agent` seam owns the transport and error handling.
  """

  alias Voyager.Agent

  @type entry :: %{required(:pid) => pid(), optional(atom()) => term()}
  @type direction :: :asc | :desc

  # Cheap, fixed-size `process_info/2` keys that are safe to fetch for every
  # process during a bulk scan. Never add unbounded keys (`:messages`,
  # `:dictionary`, `:backtrace`, `:binary`).
  @allowed_attrs ~w(
    memory reductions message_queue_len registered_name
    current_function initial_call status priority
  )a

  @doc """
  Returns the cheap-scan attributes that may be requested via `top/6`.
  """
  @spec allowed_attrs() :: [atom()]
  def allowed_attrs, do: @allowed_attrs

  @doc """
  Returns the top `limit` processes on `node` sorted by `sort_by`, each carrying
  the requested `attrs`.

  `direction` selects which end to keep and defaults to `:desc` (largest first);
  `:asc` keeps the smallest first. `sort_by` is always included in the fetched
  attributes and must resolve to an integer on the remote (e.g. `:memory`,
  `:reductions`, `:message_queue_len`). `timeout` bounds the whole remote scan.

  `search` filters the population on the remote *before* ranking: a blank value
  (`nil` or `""`) applies no filter, otherwise only processes whose `:pid` or
  any requested non-numeric attribute (`:registered_name`, `:current_function`,
  ...) contains `search` as a case-insensitive substring are considered. Numeric
  attributes are never searched. Filtering happens inside the same single scan,
  so the no-search path is unchanged and the search path only adds a per-process
  substring check.

  `attrs` and `sort_by` must be drawn from `allowed_attrs/0`; otherwise the call
  returns `{:error, {:unsupported_attrs, keys}}` without touching the remote.

  Returns `{:ok, entries}` or `{:error, reason}` on remote/transport failure.
  """
  @spec top(node(), [atom()], atom(), pos_integer(), timeout(), direction(), String.t() | nil) ::
          {:ok, [entry()]} | {:error, term()}
  def top(node, attrs, sort_by, limit, timeout, direction \\ :desc, search \\ nil)
      when direction in [:asc, :desc] do
    requested = ensure_sort_by(attrs, sort_by)

    case Enum.reject(requested, &(&1 in @allowed_attrs)) do
      [] ->
        Agent.call(
          node,
          :proc_top,
          [requested, sort_by, limit, direction, normalize_search(search)],
          timeout
        )

      unsupported ->
        {:error, {:unsupported_attrs, unsupported}}
    end
  end

  defp normalize_search(search) when search in [nil, ""], do: :undefined
  defp normalize_search(search), do: search

  defp ensure_sort_by(attrs, sort_by) do
    if sort_by in attrs, do: attrs, else: [sort_by | attrs]
  end
end

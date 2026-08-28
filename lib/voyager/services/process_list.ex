defmodule Voyager.Services.ProcessList do
  @moduledoc """
  Fetches a bounded "top N processes" list from a remote node.

  Ranking runs remotely in `:voyager_agent.proc_top` so only the top-`limit` rows
  cross the wire. To keep each row's payload independent of process state, only
  the cheap, fixed-size attributes in `@allowed_attrs` may be requested;
  unbounded ones (`:messages`, `:dictionary`, `:backtrace`, `:binary`) are
  rejected since fetching them across the whole table would copy each process's
  mailbox/heap.
  """

  alias Voyager.Agent

  @type entry :: %{required(:pid) => pid(), optional(atom()) => term()}
  @type direction :: :asc | :desc

  # Integer-valued keys the remote can rank on.
  @sortable_attrs ~w(memory reductions message_queue_len)a

  @display_attrs ~w(registered_name current_function initial_call status priority)a

  @allowed_attrs @sortable_attrs ++ @display_attrs

  @doc """
    Returns `{:ok, {entries, total}}`, where `entries` are the ranked processes and
    `total` is the number of processes walked during the scan (before
    `limit`/`search`), or
    `{:error, reason}`. Fails before touching the remote with
    `{:error, {:unsupported_attrs, keys}}` or `{:error, {:unsupported_sort_by, sort_by}}`.

    ## Arguments

      * `node` — remote node to scan.
      * `attrs` — attributes to fetch per process; must be within `@allowed_attrs`.
        `sort_by` is added if missing.
      * `sort_by` — attribute to rank on; must be within `@sortable_attrs`.
      * `limit` — maximum number of entries returned.
      * `timeout` — remote call timeout.
      * `direction` — `:desc` (default, largest first) or `:asc`.
      * `search` — case-insensitive filter on `:pid` or non-numeric attributes;
        `nil`/`""` applies no filter.
  """
  @spec top(node(), [atom()], atom(), pos_integer(), timeout(), direction(), String.t() | nil) ::
          {:ok, {[entry()], non_neg_integer()}} | {:error, term()}
  def top(node, attrs, sort_by, limit, timeout, direction \\ :desc, search \\ nil)
      when is_integer(limit) and limit > 0 and direction in [:asc, :desc] do
    requested = ensure_sort_by(attrs, sort_by)

    cond do
      (unsupported = Enum.reject(requested, &(&1 in @allowed_attrs))) != [] ->
        {:error, {:unsupported_attrs, unsupported}}

      sort_by not in @sortable_attrs ->
        {:error, {:unsupported_sort_by, sort_by}}

      true ->
        Agent.call(
          node,
          :proc_top,
          [requested, sort_by, limit, direction, normalize_search(search)],
          timeout
        )
    end
  end

  defp normalize_search(search) when search in [nil, ""], do: :undefined
  defp normalize_search(search), do: search

  defp ensure_sort_by(attrs, sort_by) do
    if sort_by in attrs, do: attrs, else: [sort_by | attrs]
  end
end

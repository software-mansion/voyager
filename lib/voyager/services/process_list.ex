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
  Returns the top `limit` processes on `node` sorted by `sort_by` (`:desc`, the
  default, largest first), each carrying the requested `attrs`.

  `sort_by` is added to `attrs` if missing. A non-blank `search` keeps only
  processes whose `:pid` or a non-numeric attribute contains it (case-insensitive);
  `nil`/`""` applies no filter.

  Without touching the remote, returns `{:error, {:unsupported_attrs, keys}}` if
  `attrs`/`sort_by` include a key outside `@allowed_attrs`, or
  `{:error, {:unsupported_sort_by, sort_by}}` if `sort_by` is a display-only key
  not in `@sortable_attrs`.

  Returns `{:ok, {entries, total}}` (`total` = process count at scan time,
  before `limit`/`search`) or `{:error, reason}`.
  """
  @spec top(node(), [atom()], atom(), pos_integer(), timeout(), direction(), String.t() | nil) ::
          {:ok, {[entry()], non_neg_integer()}} | {:error, term()}
  def top(node, attrs, sort_by, limit, timeout, direction \\ :desc, search \\ nil)
      when direction in [:asc, :desc] do
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

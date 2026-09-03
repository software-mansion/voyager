defmodule VoyagerWeb.ProcessesLive.Query do
  @moduledoc """
  Loads the process list: translates validated `ProcessListControls` into the
  remote scan and owns the attribute metadata the form and the table share.

  Ranking, searching and truncation run on the node, so `page/3` returns at
  most `limit` entries out of `scanned` walked; paging what comes back is the
  caller's.
  """

  alias Voyager.Services.ProcessList
  alias VoyagerWeb.FormSchemas.ProcessListControls

  @sortable ~w(memory reductions message_queue_len)a

  # `pid` identifies the row and `memory` is the default ranking, so neither
  # can be turned off.
  @required_attrs ~w(pid memory)a

  # Mirrors the allowlist `Voyager.Services.ProcessList` enforces remotely.
  @optional_attrs ~w(registered_name initial_call current_function reductions message_queue_len status priority)a

  @default_attrs ~w(registered_name initial_call current_function reductions message_queue_len)a

  @default_sort {:memory, :desc}

  @type entry :: %{
          required(:pid) => pid(),
          required(:memory) => integer(),
          optional(atom()) => term()
        }
  @type sort :: {atom(), ProcessList.direction()}
  @type page :: %{entries: [entry()], scanned: non_neg_integer(), fetched_at: DateTime.t()}

  @spec default_sort() :: sort()
  def default_sort, do: @default_sort

  @spec sortable_attrs() :: [atom()]
  def sortable_attrs, do: @sortable

  @spec required_attrs() :: [atom()]
  def required_attrs, do: @required_attrs

  @spec optional_attrs() :: [atom()]
  def optional_attrs, do: @optional_attrs

  @spec default_attrs() :: [atom()]
  def default_attrs, do: @default_attrs

  @doc "Keeps only known attributes, always including `required_attrs/0`, in display order."
  @spec clamp_attrs(term()) :: [atom()]
  def clamp_attrs(attrs) when is_list(attrs) do
    Enum.filter(@required_attrs ++ @optional_attrs, &(&1 in @required_attrs or &1 in attrs))
  end

  def clamp_attrs(_attrs), do: clamp_attrs(@default_attrs)

  @doc "Fetches the ranked processes `controls` ask for. `sort` is the table's, not the form's."
  @spec page(node(), ProcessListControls.t(), sort()) :: {:ok, page()} | {:error, term()}
  def page(node, %ProcessListControls{} = controls, {sort_by, direction} \\ @default_sort) do
    # Every entry carries its pid, so it is never requested.
    attrs = controls |> ProcessListControls.attrs() |> List.delete(:pid)

    with {:ok, {entries, scanned}} <-
           ProcessList.top(
             node,
             attrs,
             sort_by,
             controls.limit,
             controls.timeout,
             direction,
             controls.search
           ) do
      {:ok, %{entries: entries, scanned: scanned, fetched_at: DateTime.utc_now()}}
    end
  end
end

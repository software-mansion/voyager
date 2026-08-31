defmodule Voyager.Queries.Processes do
  @moduledoc """
  Read queries for the process list and process details of a remote node.

  Wraps `Voyager.Services.ProcessList` and `Voyager.Services.ProcessInfo` with
  the shape the UI needs: a validated set of options, a `page/2` result carrying
  the scan metadata the list page surfaces, and pid parsing/formatting so
  LiveViews never touch `:erlang.list_to_pid/1` themselves.

  Ranking, searching and truncation all run remotely, so `page/2` returns at
  most `limit` entries out of `scanned` walked processes.
  """

  alias Voyager.Services.ProcessInfo
  alias Voyager.Services.ProcessList

  @attrs ~w(registered_name initial_call current_function memory reductions message_queue_len)a

  @sortable ~w(memory reductions message_queue_len)a

  @limits [25, 50, 100, 250, 500]

  @default_limit 100

  @default_sort_by :memory

  @default_direction :desc

  @default_timeout 5_000

  @min_timeout 1_000

  @max_timeout 30_000

  @type entry :: %{required(:pid) => pid(), optional(atom()) => term()}

  @type page :: %{
          entries: [entry()],
          scanned: non_neg_integer(),
          truncated?: boolean(),
          fetched_at: DateTime.t()
        }

  @type opts :: [
          sort_by: atom(),
          direction: ProcessList.direction(),
          limit: pos_integer(),
          timeout: timeout(),
          search: String.t() | nil
        ]

  @doc "Attributes fetched for every listed process."
  @spec attrs() :: [atom()]
  def attrs, do: @attrs

  @doc "Attributes the remote can rank on."
  @spec sortable_attrs() :: [atom()]
  def sortable_attrs, do: @sortable

  @doc "Selectable values for the number of fetched processes."
  @spec limit_options() :: [pos_integer()]
  def limit_options, do: @limits

  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @spec default_sort_by() :: atom()
  def default_sort_by, do: @default_sort_by

  @spec default_direction() :: ProcessList.direction()
  def default_direction, do: @default_direction

  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout

  @doc "Inclusive bounds for the user-settable request timeout, in milliseconds."
  @spec timeout_bounds() :: {pos_integer(), pos_integer()}
  def timeout_bounds, do: {@min_timeout, @max_timeout}

  @doc """
  Fetches a ranked page of processes from `node`.

  Returns `{:ok, page}` or `{:error, reason}`. Unknown options fall back to the
  defaults, and `timeout` is clamped into `timeout_bounds/0` so a caller cannot
  tie up the connection indefinitely.
  """
  @spec page(node(), opts()) :: {:ok, page()} | {:error, term()}
  def page(node, opts \\ []) do
    sort_by = sort_by(opts[:sort_by])
    direction = direction(opts[:direction])
    limit = limit(opts[:limit])
    timeout = timeout(opts[:timeout])
    search = search(opts[:search])

    case ProcessList.top(node, @attrs, sort_by, limit, timeout, direction, search) do
      {:ok, {entries, scanned}} ->
        {:ok,
         %{
           entries: entries,
           scanned: scanned,
           truncated?: length(entries) < scanned,
           fetched_at: DateTime.utc_now()
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches full details for a single process, verifying it is still alive.

  Pids can be reused between a list scan and a drill-in, so callers get
  `{:error, :dead}` rather than details for an unrelated process.
  """
  @spec info(node(), pid()) :: {:ok, ProcessInfo.info()} | {:error, term()}
  def info(node, pid) when is_pid(pid), do: ProcessInfo.fetch(node, pid)

  @doc """
  Parses an external pid string such as `"<0.123.0>"` into a pid.

  Returns `:error` for malformed input, so a hand-edited URL cannot crash the
  page.
  """
  @spec parse_pid(String.t()) :: {:ok, pid()} | :error
  def parse_pid(pid_string) when is_binary(pid_string) do
    {:ok, pid_string |> String.to_charlist() |> :erlang.list_to_pid()}
  rescue
    ArgumentError -> :error
  end

  def parse_pid(_pid_string), do: :error

  @doc """
  Formats a pid as its external string form, e.g. `"<0.123.0>"`.
  """
  @spec format_pid(pid()) :: String.t()
  def format_pid(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  defp sort_by(value) when value in @sortable, do: value
  defp sort_by(_value), do: @default_sort_by

  defp direction(value) when value in [:asc, :desc], do: value
  defp direction(_value), do: @default_direction

  defp limit(value) when value in @limits, do: value
  defp limit(_value), do: @default_limit

  defp timeout(value) when is_integer(value),
    do: value |> max(@min_timeout) |> min(@max_timeout)

  defp timeout(_value), do: @default_timeout

  defp search(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp search(_value), do: nil
end

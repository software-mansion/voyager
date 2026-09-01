defmodule Voyager.Queries.Processes do
  @moduledoc """
  Read queries for the process list and process details of a remote node.

  Wraps `Voyager.Services.ProcessList` and `Voyager.Services.ProcessInfo` with
  the shape the UI needs: `page/3` takes the already-validated
  `VoyagerWeb.FormSchemas.ProcessListControls` and returns the rows with the
  scan metadata the list page surfaces, plus pid parsing/formatting so LiveViews
  never touch `:erlang.list_to_pid/1` themselves.

  Ranking, searching and truncation all run remotely, so `page/3` returns at
  most `limit` entries out of `scanned` walked processes. Paging is the
  caller's: every fetched row comes back.
  """

  alias Voyager.Services.ProcessInfo
  alias Voyager.Services.ProcessList
  alias VoyagerWeb.FormSchemas.ProcessListControls

  @sortable ~w(memory reductions message_queue_len)a

  # Always fetched and always shown: `pid` identifies the row and `memory` is
  # the default ranking, so neither can be turned off.
  @required_attrs ~w(pid memory)a

  # Selectable display attributes, mirroring the allowlist the remote enforces
  # in `Voyager.Services.ProcessList`.
  @optional_attrs ~w(registered_name initial_call current_function reductions message_queue_len status priority)a

  @default_attrs ~w(registered_name initial_call current_function reductions message_queue_len)a

  @refresh_intervals [
    {"Off", "off"},
    {"5s", "5000"},
    {"10s", "10000"},
    {"30s", "30000"},
    {"60s", "60000"}
  ]

  @default_sort_by :memory

  @default_direction :desc

  @type entry :: %{required(:pid) => pid(), optional(atom()) => term()}

  @type page :: %{
          entries: [entry()],
          scanned: non_neg_integer(),
          fetched_at: DateTime.t()
        }

  @doc "Default `{sort_by, direction}` for a fresh table."
  @spec default_sort() :: {atom(), ProcessList.direction()}
  def default_sort, do: {@default_sort_by, @default_direction}

  @doc "Attributes the remote can rank on."
  @spec sortable_attrs() :: [atom()]
  def sortable_attrs, do: @sortable

  @doc "Attributes that are always fetched and cannot be deselected."
  @spec required_attrs() :: [atom()]
  def required_attrs, do: @required_attrs

  @doc "Display attributes the user may add to or remove from the table."
  @spec optional_attrs() :: [atom()]
  def optional_attrs, do: @optional_attrs

  @spec default_attrs() :: [atom()]
  def default_attrs, do: @default_attrs

  @doc "Selectable auto-refresh intervals as `{label, value}` pairs."
  @spec refresh_interval_options() :: [{String.t(), String.t()}]
  def refresh_interval_options, do: @refresh_intervals

  @doc """
  Normalizes a list of selected attributes: keeps only known ones and always
  includes `required_attrs/0`.
  """
  @spec clamp_attrs(term()) :: [atom()]
  def clamp_attrs(attrs) when is_list(attrs) do
    selected = Enum.filter(attrs, &(&1 in @optional_attrs))

    Enum.filter(@required_attrs ++ @optional_attrs, &(&1 in @required_attrs or &1 in selected))
  end

  def clamp_attrs(_attrs), do: clamp_attrs(@default_attrs)

  @doc """
  Fetches the ranked processes `controls` asks for from `node`.

  The controls are already validated, so this only translates them into the
  remote call. `sort` is separate: it is a table interaction rather than a form
  field. Returns `{:ok, page}` or `{:error, reason}`.
  """
  @spec page(node(), ProcessListControls.t(), {atom(), ProcessList.direction()}) ::
          {:ok, page()} | {:error, term()}
  def page(
        node,
        %ProcessListControls{} = controls,
        sort \\ {@default_sort_by, @default_direction}
      ) do
    {sort_by, direction} = sort
    attrs = controls |> ProcessListControls.attrs() |> Enum.reject(&(&1 == :pid))

    simulate_latency()

    case ProcessList.top(
           node,
           attrs,
           sort_by(sort_by),
           controls.limit,
           controls.timeout,
           direction(direction),
           search(controls.search)
         ) do
      {:ok, {entries, scanned}} ->
        {:ok, %{entries: entries, scanned: scanned, fetched_at: DateTime.utc_now()}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp search(""), do: nil
  defp search(value), do: value

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

  # Development aid for exercising the loading and auto-refresh behaviour
  # against a fast local node. Read at call time, so it can be toggled from a
  # running IEx session without a restart:
  #
  #     Application.put_env(:voyager, :process_list_delay_ms, 2_000)
  #     Application.delete_env(:voyager, :process_list_delay_ms)
  defp simulate_latency do
    case Application.get_env(:voyager, :process_list_delay_ms) do
      ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end
  end

  defp sort_by(value) when value in @sortable, do: value
  defp sort_by(_value), do: @default_sort_by

  defp direction(value) when value in [:asc, :desc], do: value
  defp direction(_value), do: @default_direction
end

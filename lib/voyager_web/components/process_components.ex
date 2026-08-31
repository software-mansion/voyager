defmodule VoyagerWeb.Components.ProcessComponents do
  @moduledoc """
  Process-specific presentation for the process list and details pages.

  Holds the column definitions and the value formatting that the generic
  `VoyagerWeb.Components.DataTableComponents` deliberately knows nothing about.
  """

  use VoyagerWeb, :component

  alias Voyager.Queries.Processes
  alias VoyagerWeb.Formatters

  # Ordered as they appear in the table. `name` is the display column backed by
  # `registered_name`/`initial_call`, so it is shown whenever either is selected.
  # Fixed widths on the numeric columns keep values that change every refresh
  # from shifting the layout.
  @columns [
    %{key: :pid, label: "PID", sortable?: false, align: :left, width: :md},
    %{key: :name, label: "Name or initial call", sortable?: false, align: :left},
    %{key: :memory, label: "Memory", sortable?: true, align: :right, width: :sm},
    %{key: :reductions, label: "Reductions", sortable?: true, align: :right, width: :md},
    %{key: :message_queue_len, label: "MsgQ", sortable?: true, align: :right, width: :sm},
    %{key: :status, label: "Status", sortable?: false, align: :left, width: :sm},
    %{key: :priority, label: "Priority", sortable?: false, align: :left, width: :sm},
    %{key: :current_function, label: "Current function", sortable?: false, align: :left}
  ]

  # Which selected attributes make a column visible. `name` needs either of the
  # two attributes it is derived from.
  @column_attrs %{
    pid: [:pid],
    name: [:registered_name, :initial_call],
    memory: [:memory],
    reductions: [:reductions],
    message_queue_len: [:message_queue_len],
    status: [:status],
    priority: [:priority],
    current_function: [:current_function]
  }

  @labels %{
    pid: "PID",
    memory: "Memory",
    registered_name: "Name",
    initial_call: "Initial call",
    current_function: "Current function",
    reductions: "Reductions",
    message_queue_len: "MsgQ",
    status: "Status",
    priority: "Priority"
  }

  @doc "Every column definition, in display order."
  @spec columns() :: [map()]
  def columns, do: @columns

  @doc """
  Column definitions for the given selected attributes, in display order.
  """
  @spec columns([atom()]) :: [map()]
  def columns(selected) do
    Enum.filter(@columns, fn %{key: key} ->
      @column_attrs |> Map.fetch!(key) |> Enum.any?(&(&1 in selected))
    end)
  end

  @doc "Human label for a selectable attribute."
  @spec column_label(atom()) :: String.t()
  def column_label(attr), do: Map.get(@labels, attr, to_string(attr))

  @doc """
  Renders a single cell of the process table.
  """
  attr :column, :map, required: true
  attr :row, :map, required: true

  def cell(assigns) do
    ~H"""
    <%= case @column.key do %>
      <% :pid -> %>
        <span class="font-mono text-primary text-sm">{Processes.format_pid(@row.pid)}</span>
      <% :name -> %>
        <span class="font-mono text-sm" title={display_name(@row)}>{display_name(@row)}</span>
      <% :current_function -> %>
        <span
          class="font-mono text-base-content/70 text-sm"
          title={format_mfa(@row[:current_function])}
        >
          {format_mfa(@row[:current_function])}
        </span>
        <%!-- Numeric columns are fixed-width, so the full value stays reachable
            via the title when it truncates. --%>
      <% :memory -> %>
        <span class="font-mono text-sm" title={Formatters.format_bytes(@row[:memory])}>
          {Formatters.format_bytes(@row[:memory])}
        </span>
      <% :reductions -> %>
        <span class="font-mono text-sm" title={format_number(@row[:reductions])}>
          {format_number(@row[:reductions])}
        </span>
      <% :status -> %>
        <span class="font-mono text-base-content/70 text-sm">{format_atom(@row[:status])}</span>
      <% :priority -> %>
        <span class="font-mono text-base-content/70 text-sm">{format_atom(@row[:priority])}</span>
      <% :message_queue_len -> %>
        <span
          class={[
            "font-mono text-sm",
            queue_warning?(@row[:message_queue_len]) && "text-warning font-medium"
          ]}
          title={format_number(@row[:message_queue_len])}
        >
          {format_number(@row[:message_queue_len])}
        </span>
    <% end %>
    """
  end

  @doc """
  Human label for a process: its registered name when it has one, otherwise its
  initial call.
  """
  @spec display_name(map()) :: String.t()
  def display_name(%{registered_name: name}) when is_atom(name) and not is_nil(name),
    do: inspect(name)

  def display_name(%{registered_name: name}) when is_list(name) and name != [],
    do: name |> List.first() |> inspect()

  def display_name(%{initial_call: mfa}), do: format_mfa(mfa)
  def display_name(_row), do: "—"

  @doc """
  Formats an MFA tuple as `Module.function/arity`.
  """
  @spec format_mfa(term()) :: String.t()
  def format_mfa({mod, fun, arity}), do: "#{inspect(mod)}.#{fun}/#{arity}"
  def format_mfa(nil), do: "—"
  def format_mfa(other), do: inspect(other)

  defp format_atom(nil), do: "—"
  defp format_atom(value) when is_atom(value), do: to_string(value)
  defp format_atom(value), do: inspect(value)

  defp format_number(n) when is_integer(n), do: Formatters.format_integer(n)
  defp format_number(_n), do: "—"

  # A backed-up mailbox is the signal most worth spotting at a glance.
  defp queue_warning?(len) when is_integer(len), do: len > 0
  defp queue_warning?(_len), do: false
end

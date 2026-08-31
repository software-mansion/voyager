defmodule VoyagerWeb.Components.ProcessComponents do
  @moduledoc """
  Process-specific presentation for the process list and details pages.

  Holds the column definitions and the value formatting that the generic
  `VoyagerWeb.Components.DataTableComponents` deliberately knows nothing about.
  """

  use VoyagerWeb, :component

  alias Voyager.Queries.Processes
  alias VoyagerWeb.Formatters

  @columns [
    %{key: :pid, label: "PID", sortable?: false, align: :left},
    %{key: :name, label: "Name or initial call", sortable?: false, align: :left},
    %{key: :current_function, label: "Current function", sortable?: false, align: :left},
    # Fixed widths so the metrics, which change on every refresh, cannot shift
    # the columns around under the cursor.
    %{key: :memory, label: "Memory", sortable?: true, align: :right, width: :sm},
    %{key: :reductions, label: "Reductions", sortable?: true, align: :right, width: :md},
    %{key: :message_queue_len, label: "MsgQ", sortable?: true, align: :right, width: :sm}
  ]

  @doc "Column definitions for the process list table."
  @spec columns() :: [map()]
  def columns, do: @columns

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

  defp format_number(n) when is_integer(n), do: Formatters.format_integer(n)
  defp format_number(_n), do: "—"

  # A backed-up mailbox is the signal most worth spotting at a glance.
  defp queue_warning?(len) when is_integer(len), do: len > 0
  defp queue_warning?(_len), do: false
end

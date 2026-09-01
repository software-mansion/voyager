defmodule VoyagerWeb.Components.ProcessComponents do
  @moduledoc """
  Process-specific presentation for the process list and details pages.

  Holds the column definitions and the value formatting that the generic
  `VoyagerWeb.Components.DataTableComponents` deliberately knows nothing about.
  """

  use VoyagerWeb, :component

  alias Voyager.Queries.Processes
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.FormSchemas.ProcessListControls

  # Ordered as they appear in the table. Fixed widths on the numeric columns
  # keep values that change every refresh from shifting the layout.
  @columns [
    %{key: :pid, label: "PID", sortable?: false, align: :left, width: :md},
    %{key: :registered_name, label: "Name", sortable?: false, align: :left},
    %{key: :initial_call, label: "Initial call", sortable?: false, align: :left},
    %{key: :memory, label: "Memory", sortable?: true, align: :right, width: :sm},
    %{key: :reductions, label: "Reductions", sortable?: true, align: :right, width: :md},
    %{key: :message_queue_len, label: "MsgQ", sortable?: true, align: :right, width: :sm},
    %{key: :status, label: "Status", sortable?: false, align: :left, width: :sm},
    %{key: :priority, label: "Priority", sortable?: false, align: :left, width: :sm},
    %{key: :current_function, label: "Current function", sortable?: false, align: :left}
  ]

  # Which selected attribute makes a column visible.
  @column_attrs %{
    pid: [:pid],
    registered_name: [:registered_name],
    initial_call: [:initial_call],
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

  @doc """
  The controls form: search, fetch limit, request timeout and the column
  picker.

  One `<.form>` over `ProcessListControls`, so every field validates together
  and the parent gets a single `validate` event carrying the whole set. None of
  it refetches — the values apply on the next fetch.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :node_name, :string, required: true
  attr :pending?, :boolean, default: false, doc: "fetch options differ from the loaded rows"

  def controls(assigns) do
    assigns =
      assign(assigns, :column_options, ProcessListControls.column_options(&column_label/1))

    ~H"""
    <.form
      for={@form}
      id="process-controls"
      phx-change="validate"
      class="flex flex-wrap items-end justify-between gap-3"
    >
      <label class="input w-full max-w-md">
        <.icon name="icon-search" class="text-base-content/60 size-4" />
        <input
          id={@form[:search].id}
          type="search"
          name={@form[:search].name}
          value={@form[:search].value}
          phx-debounce="300"
          placeholder="Search by PID, name or initial call"
          aria-label="Search by PID, name or initial call"
        />
      </label>

      <div class="flex flex-wrap items-end gap-2">
        <.labelled_field
          field={@form[:limit]}
          label="Limit"
          help={"Limit of processes which are fetched from #{@node_name}"}
          show_errors
        >
          <select id={@form[:limit].id} name={@form[:limit].name} class="select select-sm w-24">
            <option
              :for={value <- ProcessListControls.limit_options()}
              value={value}
              selected={to_string(value) == to_string(@form[:limit].value)}
            >
              {value}
            </option>
          </select>
        </.labelled_field>

        <.labelled_field field={@form[:timeout]} label="Timeout (ms)">
          <.input
            field={@form[:timeout]}
            type="number"
            min={elem(ProcessListControls.timeout_bounds(), 0)}
            max={elem(ProcessListControls.timeout_bounds(), 1)}
            step="100"
            inputmode="numeric"
            phx-debounce="500"
            class="input input-sm input-bordered no-spinner font-mono w-24"
          />
        </.labelled_field>

        <.labelled_field field={@form[:columns]} label="Columns">
          <.multiselect
            id="process-controls-columns"
            name={@form[:columns].name}
            label="Columns"
            options={@column_options}
            selected={List.wrap(@form[:columns].value)}
          />
        </.labelled_field>
      </div>

      <p :if={@pending?} id="process-controls-pending" class="text-base-content/70 basis-full text-xs">
        <.icon name="icon-info" class="size-3.5" /> Limit and timeout apply on the next refresh.
      </p>
    </.form>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :help, :string, default: nil

  attr :show_errors, :boolean,
    default: false,
    doc: "for controls that are not an `<.input>`, which renders its own"

  slot :inner_block, required: true

  defp labelled_field(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <div class="flex items-center gap-1">
        <label for={@field.id} class="text-base-content/70 text-xs font-medium">{@label}</label>
        <.help_tooltip :if={@help} id={"#{@field.id}-help"} text={@help} />
      </div>
      {render_slot(@inner_block)}
      <p :for={{msg, _} <- @field.errors} :if={@show_errors} class="font-mono text-error text-xs">
        {msg}
      </p>
    </div>
    """
  end

  @doc """
  Caption describing the scan behind the current rows.
  """
  attr :id, :string, required: true
  attr :shown, :integer, required: true
  attr :scanned, :integer, required: true

  def scan_summary(assigns) do
    ~H"""
    <div id={@id} class="text-base-content/70 text-xs">
      Fetched <span class="font-mono text-base-content">{Formatters.format_integer(@shown)}</span>
      processes out of
      <span class="font-mono text-base-content">{Formatters.format_integer(@scanned)}</span>
    </div>
    """
  end

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
  attr :row_id, :string, required: true, doc: "stable prefix for this row's element ids"
  attr :pid_href, :string, required: true, doc: "details page for this row's process"

  def cell(assigns) do
    ~H"""
    <%= case @column.key do %>
      <% :pid -> %>
        <.pid_cell pid={@row.pid} row_id={@row_id} href={@pid_href} />
      <% :registered_name -> %>
        <.value_cell id={"#{@row_id}-name"} value={format_name(@row[:registered_name])} />
      <% :initial_call -> %>
        <.value_cell id={"#{@row_id}-initial-call"} value={format_mfa(@row[:initial_call])} muted />
      <% :current_function -> %>
        <.value_cell
          id={"#{@row_id}-current-function"}
          value={format_mfa(@row[:current_function])}
          muted
        />
      <% :memory -> %>
        <.value_cell id={"#{@row_id}-memory"} value={Formatters.format_bytes(@row[:memory])} />
      <% :reductions -> %>
        <.value_cell id={"#{@row_id}-reductions"} value={format_number(@row[:reductions])} />
      <% :status -> %>
        <.value_cell id={"#{@row_id}-status"} value={format_atom(@row[:status])} muted />
      <% :priority -> %>
        <.value_cell id={"#{@row_id}-priority"} value={format_atom(@row[:priority])} muted />
      <% :message_queue_len -> %>
        <.value_cell
          id={"#{@row_id}-msgq"}
          value={format_number(@row[:message_queue_len])}
          class={queue_warning?(@row[:message_queue_len]) && "text-warning font-medium"}
        />
    <% end %>
    """
  end

  @doc """
  A table value with a tooltip carrying the full text and a button to copy it.

  Cells are narrow and truncate, so every value needs a way to be read and
  copied in full.
  """
  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :muted, :boolean, default: false
  attr :class, :any, default: nil

  def value_cell(assigns) do
    ~H"""
    <.tooltip id={"#{@id}-tip"} interactive class="min-w-0 max-w-full" tip_class="font-mono">
      <span class={["font-mono block truncate text-sm", @muted && "text-base-content/70", @class]}>
        {@value}
      </span>
      <:content>
        <div class="flex items-center gap-1">
          <span id={"#{@id}-copy-text"}>{@value}</span>
          <.copy_button
            id={"#{@id}-copy"}
            target={"##{@id}-copy-text"}
            label="Copy value"
            icon_only
            size={:sm}
            class="text-base-content/60 shrink-0 hover:text-primary"
          />
        </div>
      </:content>
    </.tooltip>
    """
  end

  @doc """
  PID cell: a link to the process details page, with a tooltip carrying the
  full pid and a button to copy it.
  """
  attr :pid, :any, required: true
  attr :row_id, :string, required: true
  attr :href, :string, required: true

  def pid_cell(assigns) do
    assigns = assign(assigns, :pid_string, Processes.format_pid(assigns.pid))

    ~H"""
    <.tooltip
      id={"#{@row_id}-pid-tip"}
      interactive
      class="min-w-0 max-w-full"
      tip_class="font-mono"
    >
      <%!-- Only the pid navigates, so it carries the affordances of a link. --%>
      <.link
        navigate={@href}
        class="font-mono text-primary block truncate text-sm hover:underline focus-visible:underline"
      >
        {@pid_string}
      </.link>
      <:content>
        <div class="flex items-center gap-1">
          <span id={"#{@row_id}-pid-copy-text"}>{@pid_string}</span>
          <.copy_button
            id={"#{@row_id}-pid-copy"}
            target={"##{@row_id}-pid-copy-text"}
            label="Copy PID"
            icon_only
            size={:sm}
            class="text-base-content/60 shrink-0 hover:text-primary"
          />
        </div>
      </:content>
    </.tooltip>
    """
  end

  @doc """
  Formats a process's registered name.

  `:erlang.process_info/2` reports an unregistered process as `[]`, and a
  registered one as a bare atom.
  """
  @spec format_name(term()) :: String.t()
  def format_name(name) when is_atom(name) and not is_nil(name), do: inspect(name)
  def format_name([name | _rest]), do: inspect(name)
  def format_name(_name), do: "—"

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

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

  # Shown when a process has no value for a column; `value_cell/1` matches on it
  # to explain the gap rather than offering it to copy.
  @placeholder "—"

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
  and the parent gets a single `validate` event carrying the whole set.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :node_name, :string, required: true
  attr :loading?, :boolean, default: false, doc: "disables every control while a fetch runs"

  def controls(assigns) do
    assigns =
      assign(assigns, :column_options, ProcessListControls.column_options(&column_label/1))

    ~H"""
    <.form for={@form} id="process-controls" phx-change="validate" class="flex flex-col gap-1">
      <fieldset disabled={@loading?} class={["contents", @loading? && "opacity-60"]}>
        <div class="flex flex-wrap items-start justify-between gap-3">
          <label class="input mt-5 w-full max-w-md">
            <.icon name="icon-search" class="text-base-content/60 size-4" />
            <input
              id={@form[:search].id}
              type="search"
              name={@form[:search].name}
              value={@form[:search].value}
              phx-debounce="500"
              placeholder="Search by PID, name or initial call"
              aria-label="Search by PID, name or initial call"
            />
          </label>

          <div class="grid-cols-[auto_auto_auto] grid-rows-[auto_auto_auto] grid items-center gap-x-2">
            <.field_label field={@form[:limit]} label="Limit" help={limit_help(@node_name)} />
            <.field_label field={@form[:timeout]} label="Timeout (ms)" />
            <.field_label field={@form[:columns]} label="Columns" />

            <select id={@form[:limit].id} name={@form[:limit].name} class="select select-sm w-24">
              <option
                :for={value <- ProcessListControls.limit_options()}
                value={value}
                selected={to_string(value) == to_string(@form[:limit].value)}
              >
                {value}
              </option>
            </select>

            <input
              id={@form[:timeout].id}
              type="number"
              name={@form[:timeout].name}
              value={@form[:timeout].value}
              min={elem(ProcessListControls.timeout_bounds(), 0)}
              max={elem(ProcessListControls.timeout_bounds(), 1)}
              step="100"
              inputmode="numeric"
              phx-debounce="500"
              class={[
                "input input-sm input-bordered no-spinner font-mono w-24",
                @form[:timeout].errors != [] && "input-error"
              ]}
            />

            <.multiselect
              id="process-controls-columns"
              name={@form[:columns].name}
              label="Columns"
              options={@column_options}
              selected={List.wrap(@form[:columns].value)}
              disabled={@loading?}
            />

            <.field_error field={@form[:limit]} />
            <.field_error field={@form[:timeout]} />
            <span />
          </div>
        </div>
      </fieldset>
    </.form>
    """
  end

  defp limit_help(node_name), do: "Limit of processes which are fetched from #{node_name}"

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :help, :string, default: nil

  defp field_label(assigns) do
    ~H"""
    <div class="flex items-center gap-1">
      <label for={@field.id} class="text-base-content/70 text-xs font-medium">{@label}</label>
      <.help_tooltip :if={@help} id={"#{@field.id}-help"} text={@help} />
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp field_error(assigns) do
    ~H"""
    <%!-- The cell keeps the input's width and the message overflows it, so a
          long error cannot stretch the grid column and shift the controls. --%>
    <p class="font-mono text-error relative h-4 w-24 text-xs">
      <span class="absolute left-0 whitespace-nowrap">
        {@field.errors |> Enum.map_join(", ", &translate_error/1)}
      </span>
    </p>
    """
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc """
  Caption describing the scan behind the current rows.
  """
  attr :id, :string, required: true
  attr :shown, :integer, required: true
  attr :scanned, :integer, required: true
  attr :round_trip_ms, :integer, default: nil, doc: "round trip of the fetch that produced these"

  def scan_summary(assigns) do
    ~H"""
    <div id={@id} class="text-base-content/70 text-xs">
      Fetched <span class="font-mono text-base-content">{Formatters.format_integer(@shown)}</span>
      processes out of
      <span class="font-mono text-base-content">{Formatters.format_integer(@scanned)}</span>
      <span :if={@round_trip_ms} title="Round trip of the last fetch">
        in <span class={["font-mono", round_trip_class(@round_trip_ms)]}>{@round_trip_ms} ms</span>
      </span>
    </div>
    """
  end

  # A slow scan is the cost the node paid, so it is flagged where it is
  # reported rather than left for the user to read off the number.
  defp round_trip_class(ms) when ms > 3_000, do: "text-error"
  defp round_trip_class(ms) when ms > 1_000, do: "text-warning"
  defp round_trip_class(_ms), do: "text-base-content"

  @doc """
  Column definitions for the given selected attributes, in display order.
  """
  @spec columns([atom()]) :: [map()]
  def columns(selected) do
    Enum.filter(@columns, &(&1.key in selected))
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
    assigns = assign(assigns, :empty?, assigns.value == @placeholder)

    ~H"""
    <.tooltip id={"#{@id}-tip"} interactive class="min-w-0 max-w-full" tip_class="font-mono">
      <span class={["font-mono block truncate text-sm", @muted && "text-base-content/70", @class]}>
        {@value}
      </span>
      <:content>
        <%!-- Nothing to read or copy when the process has no value here, so the
              tooltip says that instead of offering an em dash. --%>
        <span :if={@empty?} class="text-base-content/70">Not set</span>
        <div :if={not @empty?} class="flex items-center gap-1">
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
  def format_name(_name), do: @placeholder

  @doc """
  Formats an MFA tuple as `Module.function/arity`.
  """
  @spec format_mfa(term()) :: String.t()
  def format_mfa({mod, fun, arity}), do: "#{inspect(mod)}.#{fun}/#{arity}"
  def format_mfa(nil), do: @placeholder
  def format_mfa(other), do: inspect(other)

  defp format_atom(nil), do: @placeholder
  defp format_atom(value) when is_atom(value), do: to_string(value)
  defp format_atom(value), do: inspect(value)

  defp format_number(n) when is_integer(n), do: Formatters.format_integer(n)
  defp format_number(_n), do: @placeholder

  # A backed-up mailbox is the signal most worth spotting at a glance.
  defp queue_warning?(len) when is_integer(len), do: len > 0
  defp queue_warning?(_len), do: false
end

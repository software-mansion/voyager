defmodule VoyagerWeb.Components.ProcessInfoComponents do
  @moduledoc """
  Tabs, panels and lists for the process info page.

  `tab_button/1` and `tab_panel/1` build the DaisyUI lift tabs; a panel's
  controls row carries the per-section fetch time, timeout and refresh button.
  `term_section/1` renders one gated, unbounded term fetch. The rest are
  generic building blocks.
  """

  use VoyagerWeb, :component

  alias Phoenix.LiveView.AsyncResult
  alias VoyagerWeb.Formatters

  @timeout_bounds {1_000, 30_000}

  @doc "Timeout bounds for the per-section timeout inputs, in milliseconds."
  @spec timeout_bounds() :: {pos_integer(), pos_integer()}
  def timeout_bounds, do: @timeout_bounds

  @doc """
  One lift tab. Must be a direct child of the `.tabs` tablist; the matching
  `tab_panel/1` is toggled by the server-tracked `active` tab.
  """
  attr :tab, :atom, required: true
  attr :active, :atom, required: true
  attr :label, :string, required: true
  attr :tooltip, :string, default: nil

  def tab_button(assigns) do
    ~H"""
    <button
      type="button"
      role="tab"
      id={"process-tab-#{@tab}"}
      phx-click="set-tab"
      phx-value-tab={@tab}
      class={["tab", @active == @tab && "tab-active"]}
    >
      <%!-- The tooltip lives on an inner span: `tabs-lift` already claims the
           tab's own pseudo-elements for its corner decoration. --%>
      <span :if={@tooltip} class="tooltip tooltip-bottom" data-tip={@tooltip}>{@label}</span>
      <span :if={is_nil(@tooltip)}>{@label}</span>
    </button>
    """
  end

  @doc """
  A lift tab's content panel: the controls row (fetch time, timeout input and
  fetch button, all scoped to `section`) above the section body.

  All panels stay in the DOM so fetched data survives tab switches; only the
  `active` one is shown. The panel fills the remaining page height and scrolls
  on its own.
  """
  attr :id, :string, required: true
  attr :section, :atom, required: true
  attr :active, :boolean, required: true
  attr :title, :string, default: nil
  attr :muted, :string, default: nil
  attr :help, :string, default: nil, doc: "renders a \"?\" tooltip next to the title"
  attr :fetched_at, DateTime, default: nil
  attr :timeout, :integer, required: true
  attr :loading?, :boolean, required: true
  attr :disabled, :boolean, required: true
  slot :inner_block, required: true

  def tab_panel(assigns) do
    assigns = assign(assigns, :bounds, @timeout_bounds)

    ~H"""
    <div class={[
      "border-base-300 bg-base-100 rounded-b-box -mt-px flex min-h-0 flex-1 flex-col border",
      not @active && "hidden"
    ]}>
      <div id={@id} class="flex min-h-0 flex-1 flex-col">
        <div class="flex flex-wrap items-center justify-between gap-3 p-5 pb-4">
          <h4
            :if={@title}
            class="text-base-content flex items-center gap-1 text-sm font-semibold leading-none"
          >
            {@title}
            <span :if={@muted} class="font-mono text-base-content/70 ml-1 text-xs font-normal">
              {@muted}
            </span>
            <.help_tooltip :if={@help} id={"#{@id}-help"} text={@help} />
          </h4>
          <span :if={is_nil(@title)} />
          <div class="flex flex-wrap items-center gap-3">
            <span
              :if={@fetched_at}
              id={"#{@id}-fetched-at"}
              class="font-mono text-base-content/70 text-xs"
            >
              fetched {Formatters.format_time(@fetched_at)} UTC
            </span>
            <form id={"#{@id}-timeout-form"} phx-change="set-timeout" class="flex items-center gap-2">
              <input type="hidden" name="section" value={@section} />
              <label for={"#{@id}-timeout"} class="text-base-content/70 text-xs font-medium">
                Timeout (ms)
              </label>
              <input
                id={"#{@id}-timeout"}
                type="number"
                name="timeout"
                value={@timeout}
                min={elem(@bounds, 0)}
                max={elem(@bounds, 1)}
                step="100"
                inputmode="numeric"
                phx-debounce="500"
                class="input input-sm input-bordered no-spinner font-mono w-24"
              />
            </form>
            <.refresh_button
              id={"#{@id}-refresh"}
              event={"fetch-#{@section}"}
              label="Fetch"
              loading?={@loading?}
              disabled={@disabled}
            />
          </div>
        </div>
        <div class="min-h-0 flex-1 overflow-y-auto px-5 pb-5">
          <div class="flex min-h-full flex-col gap-5">
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  One gated, unbounded term fetch (state, messages, dictionary).

  `result` is `nil` until the first fetch, which renders a centered notice
  pointing at the panel's fetch button; afterwards the loaded value renders
  through the inner block. A process that exposes no state is a fact, not a
  failure, so `:no_state` renders as an info notice.
  """
  attr :id, :string, required: true
  attr :result, :any, required: true, doc: "nil or an AsyncResult"
  slot :inner_block, required: true

  def term_section(assigns) do
    ~H"""
    <div :if={is_nil(@result)} id={"#{@id}-gate"} class="flex flex-1 items-center justify-center">
      <p class="text-base-content/70 text-xs">
        No data fetched yet. Use the fetch button in the top-right corner.
      </p>
    </div>
    <.async_result :let={value} :if={@result} assign={@result}>
      <:loading>
        <div id={"#{@id}-skeleton"} class="flex flex-col gap-2">
          <div class="skeleton h-3 w-2/3 rounded" />
          <div class="skeleton h-3 w-1/2 rounded" />
          <div class="skeleton h-3 w-3/5 rounded" />
        </div>
      </:loading>
      <:failed :let={reason}>
        <.fetch_alert
          id={"#{@id}-error"}
          kind={error_kind(reason)}
          message={error_message(reason)}
        />
      </:failed>
      {render_slot(@inner_block, value)}
    </.async_result>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :label, :string, required: true
  attr :loading?, :boolean, required: true
  attr :disabled, :boolean, default: false

  def refresh_button(assigns) do
    ~H"""
    <.tooltip id={"#{@id}-tip"} position="bottom">
      <button
        type="button"
        id={@id}
        phx-click={@event}
        phx-throttle="1000"
        disabled={@disabled}
        aria-label={@label}
        class="btn btn-ghost btn-square btn-sm"
      >
        <.icon name="icon-rotate-cw" class={["size-4", @loading? && "motion-safe:animate-spin"]} />
      </button>
      <:content>{@label}</:content>
    </.tooltip>
    """
  end

  attr :id, :string, required: true
  attr :message, :string, required: true
  attr :kind, :atom, default: :error, values: [:error, :info]

  def fetch_alert(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "alert border px-3 py-2.5 text-xs",
        if(@kind == :info, do: "alert-info", else: "alert-error")
      ]}
    >
      <.icon
        name={if(@kind == :info, do: "icon-info", else: "icon-circle-alert")}
        class="size-4 shrink-0"
      />
      {@message}
    </div>
    """
  end

  attr :id, :string, required: true

  def truncation_note(assigns) do
    ~H"""
    <p id={@id} class="text-base-content/70 flex items-center gap-1.5 text-xs">
      <.icon name="icon-info" class="size-3.5 shrink-0" />
      Truncated on the remote node — some entries or values are not shown.
    </p>
    """
  end

  @doc """
  A flat list of process identifiers. Pids living on the inspected node become
  links to their own process info page; ports, references, remote names and
  pids of other nodes are listed as plain chips.
  """
  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :total, :integer, required: true
  attr :node_name, :string, required: true
  attr :remote_node, :atom, required: true

  def identifier_chips(assigns) do
    assigns = assign(assigns, :overflow, max(assigns.total - length(assigns.items), 0))

    ~H"""
    <div id={@id} class="flex flex-col gap-2">
      <p :if={@items == []} class="font-mono text-base-content/70 text-xs">None</p>
      <div :if={@items != []} class="flex flex-wrap gap-1.5">
        <%= for item <- Enum.map(@items, &identifier_entry(&1, @remote_node)) do %>
          <.link
            :if={item.pid?}
            navigate={~p"/node/#{@node_name}/processes/#{item.text}"}
            class="border-base-content/70 bg-base-200 text-base-content font-mono inline-flex items-center gap-1.5 rounded-md border px-2.5 py-1 text-xs transition-colors hover:border-primary hover:text-primary"
          >
            <span class="bg-primary h-1.5 w-1.5 rounded-full" />
            {item.text}
          </.link>
          <span
            :if={not item.pid?}
            class="border-base-content/40 bg-base-200 text-base-content/80 font-mono inline-flex items-center rounded-md border px-2.5 py-1 text-xs"
          >
            {item.text}
          </span>
        <% end %>
      </div>
      <p :if={@overflow > 0} class="font-mono text-base-content/70 text-xs">
        +{Formatters.format_integer(@overflow)} more on the remote node
      </p>
    </div>
    """
  end

  @doc """
  Formats the `muted` counter of a section from a bounded result, or from an
  `AsyncResult` holding one.
  """
  @spec bounded_count(AsyncResult.t() | map() | nil) :: String.t() | nil
  def bounded_count(%AsyncResult{ok?: true, result: %{total: total}}),
    do: "(#{Formatters.format_integer(total)})"

  def bounded_count(%{total: total}), do: "(#{Formatters.format_integer(total)})"
  def bounded_count(_result), do: nil

  @spec loading?(AsyncResult.t() | nil) :: boolean()
  def loading?(%AsyncResult{loading: loading}), do: loading != nil
  def loading?(_result), do: false

  @spec error_message(term()) :: String.t()
  def error_message(:invalid_pid), do: "No process with this pid exists on the node."
  def error_message(:dead), do: "The process is no longer alive."
  def error_message(:timeout), do: "The process did not reply in time."
  def error_message(:no_state), do: "This process does not expose a state."
  def error_message(:rate_limited), do: "Too many requests. Wait a moment and retry."
  def error_message(:noconnection), do: "Node is unreachable."

  def error_message({:remote_exception, :undef}),
    do: "The Voyager agent is not loaded on this node."

  def error_message(_reason), do: "Failed to fetch process information."

  @spec error_kind(term()) :: :error | :info
  def error_kind(:no_state), do: :info
  def error_kind(_reason), do: :error

  # Monitor entries arrive as `{:process, target}` / `{:port, port}`; links and
  # monitored-by entries as bare pids and ports.
  defp identifier_entry({:process, target}, remote_node),
    do: identifier_entry(target, remote_node)

  defp identifier_entry({:port, port}, remote_node), do: identifier_entry(port, remote_node)

  defp identifier_entry(pid, remote_node) when is_pid(pid) do
    if node(pid) == remote_node do
      %{pid?: true, text: Formatters.format_pid_local(pid)}
    else
      %{pid?: false, text: "#{Formatters.format_pid_local(pid)} on #{node(pid)}"}
    end
  end

  defp identifier_entry({name, node}, _remote_node) when is_atom(name),
    do: %{pid?: false, text: "#{inspect(name)} on #{node}"}

  defp identifier_entry(other, _remote_node), do: %{pid?: false, text: inspect(other)}
end

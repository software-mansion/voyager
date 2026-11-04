defmodule VoyagerWeb.Components.TracingComponents do
  @moduledoc false

  use VoyagerWeb, :component

  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Session
  alias VoyagerWeb.Components.DataTableComponents
  alias VoyagerWeb.Components.ProcessComponents
  alias VoyagerWeb.Formatters

  @row_cap 200
  # The tooltip renders for every row, so its text is capped too.
  @tip_cap 4_000

  @spec tone(Session.t(), node() | nil) :: :running | :other_node | :failed | :open
  def tone(session, connected_node \\ nil)
  def tone(%Session{status: :running}, _connected_node), do: :running

  def tone(%Session{node: node}, connected_node)
      when not is_nil(connected_node) and node != connected_node,
      do: :other_node

  def tone(%Session{status: :stopped, stop_reason: reason}, _connected_node),
    do: if(failure?(reason), do: :failed, else: :open)

  def tone(_session, _connected_node), do: :open

  defp failure?({:tracer_down, _reason}), do: true
  defp failure?(reason), do: reason in [:node_down, :write_failed]

  @spec tone_class(:running | :other_node | :failed | :open, :chip | :dot | :label | :badge) ::
          String.t()
  def tone_class(:running, :chip),
    do:
      "border-success/30 bg-success/10 hover:bg-success/20 hover:border-success/50 focus-visible:outline-success"

  def tone_class(:running, :dot), do: "bg-success"
  def tone_class(:running, :label), do: "text-success"
  def tone_class(:running, :badge), do: "badge-success dark:text-neutral"

  def tone_class(:failed, :chip),
    do:
      "border-warning/30 bg-warning/10 hover:bg-warning/20 hover:border-warning/50 focus-visible:outline-warning"

  def tone_class(:failed, :dot), do: "bg-warning"
  def tone_class(:failed, :label), do: "text-warning"
  def tone_class(:failed, :badge), do: "badge-warning dark:text-neutral"

  def tone_class(:other_node, :chip),
    do:
      "border-info/30 bg-info/10 hover:bg-info/20 hover:border-info/50 focus-visible:outline-info"

  def tone_class(:other_node, :dot), do: "bg-info"
  def tone_class(:other_node, :label), do: "text-info"
  def tone_class(:other_node, :badge), do: "badge-info dark:text-neutral"

  def tone_class(:open, :chip),
    do:
      "border-base-300 bg-base-100 hover:bg-base-200 hover:border-base-content/20 focus-visible:outline-base-content"

  def tone_class(:open, :dot), do: "bg-base-content/40"
  def tone_class(:open, :label), do: "text-base-content/70"
  def tone_class(:open, :badge), do: "badge-ghost"

  @spec state(Session.t()) :: String.t()
  def state(%Session{status: :running}), do: "running"
  def state(%Session{status: :stopped}), do: "stopped"
  def state(%Session{status: :idle}), do: "ready"

  @spec stop_reason_label(Voyager.Services.Tracer.stop_reason()) :: String.t()
  def stop_reason_label(:stopped), do: "Stopped on request"
  def stop_reason_label(:disconnected), do: "Node disconnected"
  def stop_reason_label(:interrupted), do: "Voyager restarted during the run"
  def stop_reason_label(:event_limit), do: "Event limit reached"
  def stop_reason_label(:rate_limit), do: "Rate limit exceeded"
  def stop_reason_label(:time_limit), do: "Time limit reached"
  def stop_reason_label(:mailbox_limit), do: "Tracer mailbox limit reached"
  def stop_reason_label(:storage_limit), do: "Storage limit reached"
  def stop_reason_label(:write_failed), do: "Saving traces failed"
  def stop_reason_label(:node_down), do: "Node went down"
  def stop_reason_label({:tracer_down, _reason}), do: "Remote tracer crashed"

  @spec format_elapsed(non_neg_integer()) :: String.t()
  def format_elapsed(seconds),
    do:
      "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"

  @spec traced_mfa(Config.t()) :: String.t()
  def traced_mfa(config) do
    {module, function} = traced_mfa_parts(config)
    module <> function
  end

  @doc "`traced_mfa/1` split into the module with its dot and the `function/arity`."
  @spec traced_mfa_parts(Config.t()) :: {String.t(), String.t()}
  def traced_mfa_parts(%Config{module: module, function: function, arity: arity}),
    do: {format_module(module) <> ".", "#{function}/#{arity || "_"}"}

  defp format_module("Elixir." <> module), do: module
  defp format_module(module), do: ":" <> module

  @spec config_chips(Config.t()) :: [{atom(), String.t(), String.t()}]
  def config_chips(%Config{} = config) do
    processes =
      if config.processes == :pids,
        do: count(length(config.pids), "pid", "pids"),
        else: processes(config)

    limits =
      [
        config.max_events && count(config.max_events, "event", "events"),
        config.max_rate && "#{Formatters.format_integer(config.max_rate)}/s",
        config.max_time_ms && format_time_limit(config.max_time_ms)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    [
      {:where, "Where", "#{processes} · #{config.scope}"},
      {:capture, "Capture",
       if(config.return_trace, do: capture(config) <> " + returns", else: capture(config))},
      {:stop_after, "Stop after", limits}
    ]
  end

  @doc "Every parameter of `config`, the ones that differ from `previous` highlighted with their old value."
  attr :config, Config, required: true
  attr :previous, Config, default: nil

  def config_table(assigns) do
    assigns = assign(assigns, :rows, config_rows(assigns.config, assigns.previous))

    ~H"""
    <table class="font-mono">
      <tr :for={row <- @rows} class={row.old && "bg-primary/10 text-primary font-semibold"}>
        <td class={[
          "whitespace-nowrap py-0.5 pr-4 pl-1 align-top",
          !row.old && "text-base-content/60"
        ]}>
          {row.label}
        </td>
        <td class="break-all py-0.5 pr-1">
          <span :if={row.old} class="text-base-content/50 mr-1 font-normal line-through">
            {row.old}
          </span>
          {row.value}
        </td>
      </tr>
    </table>
    """
  end

  defp config_rows(config, previous) do
    old = if previous, do: Map.new(config_params(previous)), else: %{}

    for {label, value} <- config_params(config) do
      changed = Map.get(old, label, value)
      %{label: label, value: value, old: if(changed != value, do: changed)}
    end
  end

  defp config_params(config) do
    [
      {"Function", traced_mfa(config)},
      {"Processes", processes(config)},
      {"Scope", config.scope |> Atom.to_string() |> String.capitalize()},
      {"Capture", capture(config)},
      {"Returns", if(config.return_trace, do: "Traced", else: "Not traced")},
      {"Max events", config.max_events && Formatters.format_integer(config.max_events)},
      {"Max rate", config.max_rate && "#{Formatters.format_integer(config.max_rate)}/s"},
      {"Max time", config.max_time_ms && format_time_limit(config.max_time_ms)}
    ]
    |> Enum.map(fn {label, value} -> {label, value || "None"} end)
  end

  defp config_changes(nil, config), do: traced_mfa(config)

  defp config_changes(previous, config) do
    case Enum.filter(config_rows(config, previous), & &1.old) do
      [] -> "no changes"
      rows -> Enum.map_join(rows, " · ", &"#{&1.label} #{&1.old} → #{&1.value}")
    end
  end

  defp processes(%Config{processes: :all}), do: "All processes"
  defp processes(%Config{processes: :existing}), do: "Existing processes"
  defp processes(%Config{processes: :new}), do: "New processes"
  defp processes(%Config{processes: :pids, pids: pids}), do: Enum.join(pids, ", ")

  defp capture(%Config{capture: :args, budget: budget}),
    do: "Args ≤ #{Formatters.format_integer(budget)}"

  defp capture(_config), do: "Arity"

  defp format_time_limit(ms) when rem(ms, 1_000) != 0, do: "#{Formatters.format_integer(ms)} ms"
  defp format_time_limit(ms) when rem(ms, 60_000) != 0, do: "#{div(ms, 1_000)} s"
  defp format_time_limit(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)} min"
  defp format_time_limit(ms), do: "#{div(ms, 3_600_000)} h"

  @doc "The session's Events card: a streamed table of its log entries, newest first."
  attr :rows, :any, required: true, doc: "the `@streams` entry of the log entries"
  attr :trace_session, Session, required: true
  attr :live?, :boolean, required: true, doc: "whether new entries are still arriving"
  attr :paused?, :boolean, required: true
  attr :new_count, :integer, required: true, doc: "traces that arrived while paused"
  attr :trace_rows, :integer, required: true, doc: "trace rows the stream holds"
  attr :oldest_seq, :integer, required: true

  attr :pid_href, :any,
    default: nil,
    doc: "function from a pid to its process page; nil for plain pids"

  attr :search, :map,
    default: nil,
    doc:
      "the shown search: `query`, `total`, `shown`, `oldest_seq` and the `traces` it covered; nil for the live list"

  attr :search_form, Phoenix.HTML.Form, required: true
  attr :on_pause, :string, required: true
  attr :on_resume, :string, required: true
  attr :on_older, :string, required: true
  attr :on_search, :string, required: true

  def log(assigns) do
    config = assigns.trace_session.config

    assigns =
      assigns
      |> assign(:durations?, config.return_trace)
      |> assign(:wildcard?, config.function == "_")

    ~H"""
    <div
      id="session-log"
      class="card bg-base-100 border-base-200 text-base-content flex min-h-0 flex-1 flex-col border shadow-sm"
    >
      <div class="border-base-200 flex flex-none items-center justify-between gap-3 border-b px-5 py-2.5">
        <div class="flex items-center gap-2">
          <h2 class="text-sm font-semibold">Events</h2>
          <span
            :if={@live? and not @paused? and is_nil(@search)}
            id="log-live"
            class="badge badge-sm badge-soft badge-success gap-1.5 font-medium"
          >
            <span class="size-1.5 relative flex">
              <span class="bg-success size-full absolute inline-flex animate-ping rounded-full opacity-75"></span>
              <span class="bg-success size-1.5 relative inline-flex rounded-full"></span>
            </span>
            Live
          </span>
          <span
            :if={@paused? and is_nil(@search)}
            id="log-paused"
            class="badge badge-sm badge-soft badge-warning gap-1 font-medium"
          >
            <.icon name="icon-pause" class="size-3" /> Paused
          </span>
          <span
            :if={@search && @search.total}
            id="log-matches"
            class="badge badge-sm badge-soft badge-primary font-mono font-medium"
          >
            {count(@search.total, "match", "matches")}
          </span>
        </div>
        <div class="flex items-center gap-2">
          <.form
            for={@search_form}
            id="log-search-form"
            phx-change={@on_search}
            phx-submit={@on_search}
          >
            <label
              id="log-search-field"
              phx-hook=".SearchShortcut"
              class="input input-sm w-80 transition-shadow focus-within:shadow-sm"
            >
              <.icon name="icon-search" class="text-base-content/60 size-4" />
              <input
                id="log-search"
                type="search"
                name={@search_form[:query].name}
                value={@search_form[:query].value}
                phx-debounce="300"
                disabled={@trace_session.traces == 0 and is_nil(@search)}
                placeholder={search_placeholder(@trace_session)}
                aria-label="Search traces"
                class="peer"
              />
              <kbd
                :if={@trace_session.traces > 0}
                class="bg-base-content/10 text-base-content/70 min-w-5 font-sans hidden h-5 items-center justify-center rounded-sm px-1 text-xs peer-placeholder-shown:inline-flex"
              >
                /
              </kbd>
            </label>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".SearchShortcut">
              export default {
                mounted() {
                  this.onKey = (e) => {
                    if (e.key !== "/" || e.target.closest("input, textarea, select, [contenteditable]")) return
                    e.preventDefault()
                    this.el.querySelector("input").focus()
                  }
                  window.addEventListener("keydown", this.onKey)
                },
                destroyed() {
                  window.removeEventListener("keydown", this.onKey)
                }
              }
            </script>
          </.form>
          <button
            :if={@live? and not @paused? and is_nil(@search)}
            type="button"
            id="log-pause"
            phx-click={@on_pause}
            class="btn btn-sm"
          >
            <.icon name="icon-pause" class="size-3.5" /> Pause view
          </button>
          <button
            :if={@paused? and is_nil(@search)}
            type="button"
            id="log-resume"
            phx-click={@on_resume}
            class="btn btn-sm btn-primary"
          >
            <.icon name="icon-play" class="size-3.5" /> Resume view
            <span
              :if={@new_count > 0}
              id="log-new-count"
              class="badge badge-xs bg-primary-content/20 text-primary-content font-mono border-0"
            >
              {Formatters.format_integer(@new_count)} new
            </span>
          </button>
        </div>
      </div>
      <div class="min-h-0 flex-1 overflow-auto px-5">
        <table class="table-pin-rows table-md table w-full table-fixed">
          <thead>
            <tr class="font-mono tracking-label text-base-content/70 text-xs font-semibold uppercase">
              <th class="bg-base-100 w-36 py-3">Time</th>
              <th class="bg-base-100 w-38 py-3">PID</th>
              <th class="bg-base-100 py-3">
                {if @wildcard?, do: "Call / result", else: "Arguments / result"}
              </th>
              <th :if={@durations?} id="log-duration" class="bg-base-100 w-28 py-3 text-right">
                Duration
              </th>
            </tr>
          </thead>
          <tbody id="session-log-rows" phx-update="stream">
            <.log_row
              :for={{dom_id, entry} <- @rows}
              id={dom_id}
              entry={entry}
              durations?={@durations?}
              wildcard?={@wildcard?}
              pid_href={@pid_href}
              query={@search && @search.query}
            />
          </tbody>
        </table>
        <p
          :if={@search && @search.total == 0}
          id="log-no-matches"
          class="text-base-content/70 py-6 text-center text-sm"
        >
          No traces match the search.
        </p>
      </div>
      <div
        id="log-footer"
        class="border-base-200 min-h-11 flex flex-none items-center justify-between gap-3 border-t px-5 py-1.5"
      >
        <p class="text-base-content/70 min-w-0 truncate text-xs">
          {footer(@search, @trace_session, @trace_rows, @oldest_seq)}
        </p>
        <div class="flex shrink-0 items-center gap-4">
          <span id="log-legend" class="text-base-content/70 flex items-center gap-3 text-xs">
            <span
              :for={type <- if(@durations?, do: [:call, :return, :exception], else: [:call])}
              class="flex items-center gap-1"
            >
              <.icon name={glyph(type)} class={["size-3.5", glyph_class(type)]} />
              {type_label(type)}
            </span>
          </span>
          <button
            :if={older?(@search, @oldest_seq)}
            type="button"
            id="log-older"
            phx-click={@on_older}
            class="btn btn-sm"
          >
            <.icon name="icon-move-down" class="size-3.5" /> Load older
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :durations?, :boolean, required: true
  attr :wildcard?, :boolean, required: true
  attr :pid_href, :any, required: true
  attr :query, :string, default: nil

  defp log_row(%{entry: %{kind: :trace}} = assigns) do
    ~H"""
    <tr id={@id} class="h-11 hover:bg-base-content/3">
      <td class="font-mono text-base-content/70 truncate py-2 text-sm">{format_at(@entry.at)}</td>
      <td class="py-2">
        <ProcessComponents.pid_cell
          :if={@pid_href}
          pid={@entry.pid}
          row_id={@id}
          href={@pid_href.(@entry.pid)}
        />
        <DataTableComponents.value_cell
          :if={!@pid_href}
          id={"#{@id}-pid"}
          value={Formatters.pid(@entry.pid)}
          class="text-primary"
        />
      </td>
      <td class="py-2">
        <div class="flex items-center gap-2">
          <.icon
            name={glyph(@entry.type)}
            class={["size-3.5 shrink-0", glyph_class(@entry.type)]}
            role="img"
            aria-label={type_label(@entry.type)}
          />
          <.tooltip
            id={"#{@id}-term"}
            interactive
            pinnable={false}
            class="min-w-0"
            tip_class="font-mono max-w-xl!"
          >
            <span tabindex="0" class="font-mono block min-w-0 truncate text-sm">
              <span :if={@wildcard? and @entry.type != :call} class="text-base-content/50 mr-1">
                {fun_arity(@entry.mfa)}
              </span>
              <span class={term_class(@entry.type)}>
                {highlight(term_text(@entry, @wildcard?, :row), @query)}
              </span>
            </span>
            <:content>
              <div class="flex items-start gap-1">
                <span
                  id={"#{@id}-term-text"}
                  class="max-h-80 overflow-auto whitespace-pre-wrap break-all"
                >{term_text(@entry, @wildcard?, :tip)}</span>
                <.copy_button
                  id={"#{@id}-term-copy"}
                  target={"##{@id}-term-text"}
                  label="Copy value"
                  icon_only
                  size={:sm}
                  class="text-base-content/60 shrink-0 hover:text-primary"
                />
              </div>
            </:content>
          </.tooltip>
          <.tooltip :if={@entry[:truncated]} id={"#{@id}-truncated"} class="shrink-0">
            <.icon
              name="icon-circle-alert"
              class="text-warning size-3.5"
              role="img"
              aria-label="Truncated on the remote node"
            />
            <:content>Truncated on the remote node to fit the capture budget</:content>
          </.tooltip>
        </div>
      </td>
      <td :if={@durations?} class="font-mono truncate py-2 text-right text-sm">
        {format_duration(@entry[:duration_us])}
      </td>
    </tr>
    """
  end

  defp log_row(%{entry: %{kind: :configured} = entry} = assigns) do
    detail =
      [by(entry.origin), config_changes(entry[:previous], entry.config)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    assigns = assign(assigns, :detail, detail)

    ~H"""
    <tr id={@id} class="bg-base-200 h-11">
      <td colspan={if @durations?, do: 4, else: 3} class="py-2">
        <div class="flex items-center gap-2">
          <.icon name="icon-settings" class="text-base-content/70 size-4 shrink-0" />
          <span class="text-sm font-medium">Configured</span>
          <.tooltip id={"#{@id}-config"} position="bottom" class="min-w-0">
            <span
              id={"#{@id}-changes"}
              tabindex="0"
              class="font-mono text-base-content/70 block truncate text-xs"
            >
              {@detail}
            </span>
            <:content>
              <.config_table config={@entry.config} previous={@entry[:previous]} />
            </:content>
          </.tooltip>
        </div>
      </td>
    </tr>
    """
  end

  defp log_row(assigns) do
    {icon, icon_class, row_class, title, detail} = control(assigns.entry)

    assigns =
      assign(assigns,
        icon: icon,
        icon_class: icon_class,
        row_class: row_class,
        title: title,
        detail: detail
      )

    ~H"""
    <tr id={@id} class={["h-11", @row_class]}>
      <td colspan={if @durations?, do: 4, else: 3} class="py-2">
        <div class="flex items-center gap-2">
          <.icon name={@icon} class={["size-4 shrink-0", @icon_class]} />
          <span class="text-sm font-medium">{@title}</span>
          <span :if={@detail} class="font-mono text-base-content/70 min-w-0 truncate text-xs">
            {@detail}
          </span>
        </div>
      </td>
    </tr>
    """
  end

  defp control(%{kind: :started, origin: origin}),
    do: {"icon-play", "text-success", "bg-base-200", "Started", by(origin)}

  defp control(%{kind: :stopped, reason: :stopped, origin: origin}),
    do: {"icon-square", "text-base-content/70", "bg-base-200", "Stopped", by(origin)}

  defp control(%{kind: :stopped, reason: reason}) do
    if failure?(reason),
      do: {"icon-square", "text-warning", "bg-warning/10", "Stopped", stop_reason_label(reason)},
      else:
        {"icon-square", "text-base-content/70", "bg-base-200", "Stopped",
         stop_reason_label(reason)}
  end

  defp control(%{kind: :dropped, count: count}),
    do:
      {"icon-circle-alert", "text-warning", "bg-warning/10",
       "#{Formatters.format_integer(count)} events dropped", nil}

  defp control(%{kind: :evicted}),
    do:
      {"icon-info", "text-info", "bg-info/10", "Older events evicted",
       "only the newest 500 stay in memory"}

  defp by(:ui), do: "by UI"
  defp by(:mcp), do: "by MCP"
  defp by(_origin), do: nil

  defp glyph(:call), do: "icon-arrow-right"
  defp glyph(:return), do: "icon-arrow-left"
  defp glyph(:exception), do: "icon-x"

  defp glyph_class(:call), do: "text-base-content/50"
  defp glyph_class(:return), do: "text-success"
  defp glyph_class(:exception), do: "text-error"

  defp term_class(:call), do: "text-base-content"
  defp term_class(:return), do: "text-code-atom"
  defp term_class(:exception), do: "text-error"

  defp term_text(%{type: :call, args: args, mfa: {_module, function, _arity}}, wildcard?, size)
       when is_list(args) do
    name = if wildcard?, do: Atom.to_string(function), else: ""
    cap(name <> "(" <> Enum.map_join(args, ", ", &format_term(&1, size)) <> ")", size)
  end

  defp term_text(%{type: :call, mfa: mfa}, _wildcard?, _size), do: fun_arity(mfa)

  defp term_text(%{type: :exception, value: {class, reason}}, _wildcard?, size),
    do: cap(format_term(class, size) <> ", " <> format_term(reason, size), size)

  defp term_text(%{value: value}, _wildcard?, size), do: cap(format_term(value, size), size)

  defp fun_arity({_module, function, arity}), do: "#{function}/#{arity}"

  defp format_term(term, :row),
    do: Formatters.format_term(term, limit: 20, printable_limit: @row_cap)

  defp format_term(term, :tip),
    do: Formatters.format_term(term, limit: :infinity, printable_limit: @tip_cap)

  defp cap(text, size) do
    cap = if size == :row, do: @row_cap, else: @tip_cap

    if String.length(text) > cap,
      do: String.slice(text, 0, cap) <> "…",
      else: text
  end

  defp type_label(:call), do: "Call"
  defp type_label(:return), do: "Return"
  defp type_label(:exception), do: "Exception"

  defp highlight(text, nil), do: text

  defp highlight(text, query) do
    {parts, from} =
      text
      |> String.downcase(:ascii)
      |> :binary.matches(String.downcase(query, :ascii))
      |> Enum.map_reduce(0, fn {at, length}, from ->
        {[
           escape(binary_part(text, from, at - from)),
           ~s(<mark class="bg-warning/30 rounded-sm text-inherit">),
           escape(binary_part(text, at, length)),
           "</mark>"
         ], at + length}
      end)

    {:safe, [parts, escape(binary_part(text, from, byte_size(text) - from))]}
  end

  defp escape(text), do: text |> html_escape() |> elem(1)

  defp search_placeholder(%Session{traces: 0}), do: "No traces to search yet"

  defp search_placeholder(%Session{id: id, traces: traces}) when id > 0,
    do: "Search all #{Formatters.format_integer(traces)} traces"

  defp search_placeholder(_session), do: "Search newest 500 events"

  defp format_at(at) do
    at
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.truncate(:millisecond)
    |> Calendar.strftime("%H:%M:%S.%f")
  end

  defp format_duration(nil), do: nil

  defp format_duration(us) when us < 10_000,
    do: :erlang.float_to_binary(us / 1_000, decimals: 2) <> " ms"

  defp format_duration(us) when us < 100_000,
    do: :erlang.float_to_binary(us / 1_000, decimals: 1) <> " ms"

  defp format_duration(us), do: Formatters.format_integer(round(us / 1_000)) <> " ms"

  defp older?(nil, oldest_seq), do: oldest_seq > 0
  defp older?(%{total: total, shown: shown}, _oldest_seq), do: is_integer(total) and shown < total

  defp footer(%{total: nil}, _session, _trace_rows, _oldest_seq), do: "Searching…"

  defp footer(%{total: 0} = search, session, _trace_rows, _oldest_seq),
    do: "No matches in #{search_scope(session, search)}"

  defp footer(%{total: total, shown: shown} = search, session, _trace_rows, _oldest_seq)
       when shown < total,
       do:
         "Newest #{Formatters.format_integer(shown)} of #{Formatters.format_integer(total)} matches in #{search_scope(session, search)}"

  defp footer(%{total: total} = search, session, _trace_rows, _oldest_seq),
    do: "#{count(total, "match", "matches")} in #{search_scope(session, search)}"

  defp footer(nil, %Session{traces: 0}, _trace_rows, _oldest_seq), do: "No traces yet"
  defp footer(nil, session, trace_rows, oldest_seq), do: footer(session, trace_rows, oldest_seq)

  defp footer(session, trace_rows, oldest_seq) when oldest_seq > 0,
    do:
      "Newest #{Formatters.format_integer(trace_rows)} of #{Formatters.format_integer(session.traces)} traces"

  defp footer(%Session{save: false, traces: traces}, trace_rows, _oldest_seq)
       when trace_rows < traces,
       do:
         "All #{Formatters.format_integer(trace_rows)} kept events shown · #{Formatters.format_integer(traces)} traced"

  defp footer(session, _trace_rows, _oldest_seq),
    do: "All #{count(session.traces, "trace", "traces")} shown"

  defp search_scope(%Session{id: id}, %{traces: traces}) when id > 0,
    do: count(traces, "trace", "traces")

  defp search_scope(_session, %{traces: traces}) when traces > 500,
    do:
      "the newest 500 events · #{Formatters.format_integer(traces - 500)} older traces are no longer in memory"

  defp search_scope(_session, _search), do: "the newest 500 events"

  defp count(1, singular, _plural), do: "1 #{singular}"
  defp count(n, _singular, plural), do: "#{Formatters.format_integer(n)} #{plural}"
end

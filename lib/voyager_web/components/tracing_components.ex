defmodule VoyagerWeb.Components.TracingComponents do
  @moduledoc false

  use VoyagerWeb, :component

  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Session
  alias VoyagerWeb.Components.ProcessComponents
  alias VoyagerWeb.Formatters

  @term_cap 200

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

  @spec traced_mfa(Config.t()) :: String.t()
  def traced_mfa(%Config{module: module, function: function, arity: arity}),
    do: "#{format_module(module)}.#{function}/#{arity || "_"}"

  defp format_module("Elixir." <> module), do: module
  defp format_module(module), do: ":" <> module

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

  attr :on_pause, :string, required: true
  attr :on_resume, :string, required: true
  attr :on_older, :string, required: true

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
            :if={@live? and not @paused?}
            id="log-live"
            class="badge badge-sm badge-soft badge-success font-mono"
          >
            live
          </span>
          <span :if={@paused?} id="log-paused" class="badge badge-sm badge-ghost font-mono">
            paused
          </span>
          <span :if={@paused?} id="log-new-count" class="text-base-content/70 text-xs">
            {Formatters.format_integer(@new_count)} new {if @new_count == 1,
              do: "event",
              else: "events"}
          </span>
        </div>
        <div class="flex items-center gap-2">
          <button
            :if={@live? and not @paused?}
            type="button"
            id="log-pause"
            phx-click={@on_pause}
            class="btn btn-sm"
          >
            <.icon name="icon-pause" class="size-3.5" /> Pause view
          </button>
          <button
            :if={@paused?}
            type="button"
            id="log-resume"
            phx-click={@on_resume}
            class="btn btn-sm btn-primary"
          >
            <.icon name="icon-play" class="size-3.5" /> Resume view
          </button>
        </div>
      </div>
      <div class="min-h-0 flex-1 overflow-auto px-5">
        <table class="table-pin-rows table-md table w-full table-fixed">
          <thead>
            <tr class="font-mono tracking-label text-base-content/70 text-xs font-semibold uppercase">
              <th class="bg-base-100 w-36 py-3">Time</th>
              <th class="bg-base-100 w-38 py-3">PID</th>
              <th class="bg-base-100 py-3">Arguments / result</th>
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
            />
          </tbody>
        </table>
      </div>
      <div
        id="log-footer"
        class="border-base-200 min-h-11 flex flex-none items-center justify-between gap-3 border-t px-5 py-1.5"
      >
        <p class="text-base-content/70 text-xs">
          {footer(@trace_session, @trace_rows, @oldest_seq)}
        </p>
        <button
          :if={@oldest_seq > 0}
          type="button"
          id="log-older"
          phx-click={@on_older}
          class="btn btn-sm"
        >
          <.icon name="icon-move-down" class="size-3.5" /> Load older
        </button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :durations?, :boolean, required: true
  attr :wildcard?, :boolean, required: true
  attr :pid_href, :any, required: true

  defp log_row(%{entry: %{kind: :trace}} = assigns) do
    ~H"""
    <tr id={@id} class="hover:bg-base-content/3">
      <td class="font-mono text-base-content/70 truncate py-2 text-sm">{format_at(@entry.at)}</td>
      <td class="py-2">
        <ProcessComponents.pid_cell
          :if={@pid_href}
          pid={@entry.pid}
          row_id={@id}
          href={@pid_href.(@entry.pid)}
        />
        <span :if={!@pid_href} class="font-mono text-primary block truncate text-sm">
          {Formatters.pid(@entry.pid)}
        </span>
      </td>
      <td class="py-2">
        <div class="flex items-center gap-2">
          <.icon
            name={glyph(@entry.type)}
            class={["size-3.5 shrink-0", glyph_class(@entry.type)]}
            role="img"
            aria-label={@entry.type}
          />
          <span class="font-mono block min-w-0 truncate text-sm">
            <span :if={@wildcard? and @entry.type != :call} class="text-base-content/50 mr-1">
              {fun_arity(@entry.mfa)}
            </span>
            <span class={term_class(@entry.type)}>{term_text(@entry, @wildcard?)}</span>
          </span>
          <.icon
            :if={@entry[:truncated]}
            name="icon-circle-alert"
            class="text-warning size-3.5 shrink-0"
            role="img"
            aria-label="Truncated on the remote node"
          />
        </div>
      </td>
      <td :if={@durations?} class="font-mono truncate py-2 text-right text-sm">
        {format_duration(@entry[:duration_us])}
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
    <tr id={@id} class={@row_class}>
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

  defp control(%{kind: :configured, origin: origin}),
    do: {"icon-settings", "text-base-content/70", "bg-base-200", "Configured", by(origin)}

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

  defp term_text(%{type: :call, args: args, mfa: {_module, function, _arity}}, wildcard?)
       when is_list(args) do
    name = if wildcard?, do: Atom.to_string(function), else: ""
    cap(name <> "(" <> Enum.map_join(args, ", ", &format_term/1) <> ")")
  end

  defp term_text(%{type: :call, mfa: mfa}, _wildcard?), do: fun_arity(mfa)

  defp term_text(%{type: :exception, value: {class, reason}}, _wildcard?),
    do: cap(format_term(class) <> ", " <> format_term(reason))

  defp term_text(%{value: value}, _wildcard?), do: cap(format_term(value))

  defp fun_arity({_module, function, arity}), do: "#{function}/#{arity}"

  defp format_term(term),
    do: Formatters.format_term(term, limit: 20, printable_limit: @term_cap)

  defp cap(text) do
    if String.length(text) > @term_cap,
      do: String.slice(text, 0, @term_cap) <> "…",
      else: text
  end

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

  defp footer(session, trace_rows, oldest_seq) when oldest_seq > 0,
    do:
      "Newest #{Formatters.format_integer(trace_rows)} of #{Formatters.format_integer(session.traces)} traces"

  defp footer(%Session{save: false, traces: traces}, trace_rows, _oldest_seq)
       when trace_rows < traces,
       do:
         "All #{Formatters.format_integer(trace_rows)} kept events shown · #{Formatters.format_integer(traces)} traced"

  defp footer(session, _trace_rows, _oldest_seq),
    do: "All #{Formatters.format_integer(session.traces)} traces shown"
end

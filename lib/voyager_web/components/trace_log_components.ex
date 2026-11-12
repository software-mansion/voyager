defmodule VoyagerWeb.Components.TraceLogComponents do
  @moduledoc """
  The tracing session page's Events card: the streamed table of a session's log
  entries, newest first, with its live/paused controls and its footer.
  """

  use VoyagerWeb, :component

  alias Voyager.Services.TermSyntax
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Session
  alias VoyagerWeb.Components.DataTableComponents
  alias VoyagerWeb.Components.ProcessComponents
  alias VoyagerWeb.Components.TermComponents
  alias VoyagerWeb.Components.TracingComponents
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.TermHighlight
  alias VoyagerWeb.TermTree.Segment

  @row_cap 100
  @muted_glyph "bg-base-content/10 text-base-content/70"
  # The tooltip renders for every row and cannot scroll, so its terms share a line budget.
  @tip_lines 16
  @tip_width 90
  @kept_traces Tracer.kept_traces()

  @doc "The session's Events card: a streamed table of its log entries, newest first."
  attr :rows, :any, required: true, doc: "the `@streams` entry of the log entries"
  attr :trace_session, Session, required: true
  attr :live?, :boolean, required: true, doc: "whether new entries are still arriving"
  attr :paused?, :boolean, required: true
  attr :new_count, :integer, required: true, doc: "traces that arrived while paused"
  attr :trace_rows, :integer, required: true, doc: "trace rows the stream holds"
  attr :oldest_seq, :integer, required: true

  attr :node_name, :string,
    default: nil,
    doc: "the connected node's name, whose process pages its pids link to; nil for plain pids"

  attr :node, :atom, default: nil, doc: "the connected node"
  attr :on_pause, :string, required: true
  attr :on_resume, :string, required: true
  attr :on_older, :string, required: true
  attr :on_ack, :string, required: true, doc: "pushed once the browser applied a live flush"

  def log(assigns) do
    config = assigns.trace_session.config

    assigns =
      assigns
      |> assign(:durations?, config.return_trace)
      |> assign(:wildcard?, config.function == "_")
      |> assign(:syntax, TermSyntax.current())

    ~H"""
    <div
      id="session-log"
      class="card bg-base-100 border-base-200 text-base-content flex min-h-0 flex-1 flex-col border shadow-sm"
    >
      <%!-- A hook push locks its element until the reply, so an empty one keeps the rows out of it. --%>
      <span id="session-log-ack" phx-hook=".LogAck" data-ack-event={@on_ack} hidden></span>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".LogAck">
        export default {
          mounted() {
            this.handleEvent("log-flushed", () => this.pushEvent(this.el.dataset.ackEvent, {}))
          }
        }
      </script>
      <%!-- One tip for all rows: a hidden tip still takes part in layout, and each patch walks it. --%>
      <.tooltip_portal id="log-term" interactive tip_class="max-w-3xl!">
        <div id="log-term-slot" phx-update="ignore" data-tooltip-slot></div>
      </.tooltip_portal>
      <ProcessComponents.pid_tip :if={@node_name} id="log-pid" />
      <.tooltip_portal id="log-truncated">
        <span id="log-truncated-slot" phx-update="ignore" data-tooltip-slot></span>
      </.tooltip_portal>
      <div class="border-base-200 flex flex-none items-center justify-between gap-3 border-b px-5 py-2.5">
        <div class="flex items-center gap-2">
          <h2 class="text-sm font-semibold">Events</h2>
          <span
            :if={@live? and not @paused?}
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
            :if={@paused?}
            id="log-paused"
            class="badge badge-sm badge-soft badge-warning gap-1 font-medium"
          >
            <.icon name="icon-pause" class="size-3" /> Paused
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
              syntax={@syntax}
              node={@node}
              node_name={@node_name}
            />
          </tbody>
        </table>
      </div>
      <div
        id="log-footer"
        class="border-base-200 min-h-11 flex flex-none items-center justify-between gap-3 border-t px-5 py-1.5"
      >
        <p class="text-base-content/70 min-w-0 truncate text-xs">
          {footer(@trace_session, @trace_rows, @oldest_seq, @new_count)}
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
    </div>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :durations?, :boolean, required: true
  attr :wildcard?, :boolean, required: true
  attr :syntax, :atom, required: true
  attr :node, :atom, default: nil
  attr :node_name, :string, default: nil

  defp log_row(%{entry: %{kind: :trace}} = assigns) do
    assigns =
      assigns
      |> assign(:process, process_label(assigns.entry[:process]))
      # A reconfigure can move a session to another node, so each pid links only to its own.
      |> assign(:link?, assigns.node_name && node(assigns.entry.pid) == assigns.node)

    ~H"""
    <%!-- A blocking fade holds back every patch, and rows stream in faster than it ends. --%>
    <tr
      id={@id}
      phx-mounted={
        @entry[:live] &&
          JS.transition({"transition-colors duration-1000", "bg-success/10", ""},
            time: 1000,
            blocking: false
          )
      }
      class={[
        "h-11",
        if(@entry.type == :exception,
          do: "bg-error/5 hover:bg-error/10",
          else: "hover:bg-base-content/3"
        )
      ]}
    >
      <.time_cell at={@entry.at} />
      <td class="py-2">
        <ProcessComponents.pid_cell
          :if={@link?}
          pid={@entry.pid}
          row_id={@id}
          href={~p"/node/#{@node_name}/processes/#{Formatters.format_pid(@entry.pid)}"}
          tip="#log-pid-tip"
        />
        <DataTableComponents.value_cell
          :if={!@link?}
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
            class="min-w-0 flex-1"
            tip="#log-term-tip"
          >
            <span tabindex="0" class="font-mono block min-w-0 truncate text-sm">
              <span :if={@wildcard? and @entry.type != :call} class="text-base-content/50 mr-1">
                {fun_arity(@entry.mfa)}
              </span>
              <span class={term_class(@entry.type)}>
                <.highlighted
                  text={term_text(@entry, @wildcard?)}
                  syntax={if plain?(@entry), do: nil, else: @syntax}
                />
              </span>
            </span>
            <:content>
              <div class="border-base-200 font-mono mb-2 flex flex-col gap-1 border-b pb-2">
                <div class="flex items-center gap-2">
                  <.icon
                    name={glyph(@entry.type)}
                    class={["size-3.5 shrink-0", glyph_class(@entry.type)]}
                  />
                  <span class="min-w-0 truncate font-semibold">
                    <.highlighted text={Formatters.format_mfa(@entry.mfa)} syntax={@syntax} />
                  </span>
                  <span class="text-base-content/60 font-sans ml-auto shrink-0">
                    {tip_meta(@entry)}
                  </span>
                </div>
                <div class="flex items-center gap-2">
                  <span class="text-primary shrink-0">{Formatters.pid(@entry.pid)}</span>
                  <span :if={@process} class="min-w-0 truncate">
                    <.highlighted text={@process} syntax={@syntax} />
                  </span>
                  <span class="text-base-content/60 font-sans ml-auto shrink-0">
                    {full_at(@entry.at)}
                  </span>
                </div>
              </div>
              <div
                :for={{label, text, cut?} <- tip_terms(@entry)}
                class="font-mono flex gap-3"
              >
                <span :if={label} class="text-base-content/50 min-w-5 shrink-0 text-right">
                  {label}
                </span>
                <span class="min-w-0 flex-1 whitespace-pre-wrap break-all"><.highlighted
                  text={text}
                  syntax={@syntax}
                /><span :if={cut?} class="text-base-content/50">…</span></span>
              </div>
            </:content>
          </.tooltip>
          <.tooltip
            :if={@entry[:truncated]}
            id={"#{@id}-truncated"}
            class="shrink-0"
            tip="#log-truncated-tip"
          >
            <.icon
              name="icon-circle-alert"
              class="text-base-content/40 size-3.5 transition-colors hover:text-warning"
              tabindex="0"
              role="img"
              aria-label="Truncated on the remote node"
            />
            <:content>Truncated on the remote node to fit the capture budget</:content>
          </.tooltip>
        </div>
      </td>
      <td :if={@durations?} class="font-mono truncate py-2 text-right text-sm tabular-nums">
        {format_duration(@entry[:duration_us])}
      </td>
    </tr>
    """
  end

  defp log_row(%{entry: %{kind: :configured}} = assigns) do
    ~H"""
    <tr id={@id} class="bg-base-200 h-9">
      <.time_cell at={@entry.at} />
      <td colspan={if @durations?, do: 3, else: 2} class="py-2">
        <div class="flex items-center gap-2">
          <.control_glyph icon="icon-settings" class="bg-base-content/10 text-base-content/70" />
          <span class="text-sm font-medium">Configured</span>
          <.tooltip id={"#{@id}-config"} position="bottom" class="min-w-0">
            <span
              id={"#{@id}-changes"}
              tabindex="0"
              class="font-mono text-base-content/60 block truncate text-xs"
            >
              <span :if={by(@entry.origin)}>{by(@entry.origin)} · </span>
              <TracingComponents.config_changes config={@entry.config} previous={@entry[:previous]} />
            </span>
            <:content>
              <TracingComponents.config_table config={@entry.config} previous={@entry[:previous]} />
            </:content>
          </.tooltip>
        </div>
      </td>
    </tr>
    """
  end

  defp log_row(assigns) do
    {icon, glyph_class, row_class, title, detail} = control(assigns.entry)

    assigns =
      assign(assigns,
        icon: icon,
        glyph_class: glyph_class,
        row_class: row_class,
        title: title,
        detail: detail
      )

    ~H"""
    <tr id={@id} class={["h-9", @row_class]}>
      <.time_cell at={@entry[:at]} />
      <td colspan={if @durations?, do: 3, else: 2} class="py-2">
        <div class="flex items-center gap-2">
          <.control_glyph icon={@icon} class={@glyph_class} />
          <span class="text-sm font-medium">{@title}</span>
          <span :if={@detail} class="font-mono text-base-content/70 min-w-0 truncate text-xs">
            {@detail}
          </span>
        </div>
      </td>
    </tr>
    """
  end

  attr :text, :string, required: true
  attr :syntax, :atom, required: true, doc: "nil renders the text unkinded"

  defp highlighted(assigns) do
    ~H"""
    <span
      :for={{kind, marked?, text} <- TermHighlight.parts(@text, @syntax)}
      class={kind && TermComponents.segment_class(%Segment{kind: kind})}
    ><mark :if={marked?} class="bg-warning/30 rounded-sm text-inherit">{text}</mark>{if !marked?,
      do: text}</span>
    """
  end

  attr :at, :integer, default: nil

  defp time_cell(%{at: nil} = assigns), do: ~H"<td></td>"

  defp time_cell(assigns) do
    {clock, millis} =
      assigns.at
      |> format_at()
      |> String.split_at(8)

    assigns = assign(assigns, clock: clock, millis: millis)

    ~H"""
    <td class="font-mono truncate py-2 text-sm tabular-nums" title={full_at(@at)}>
      <span class="text-base-content/50">{@clock}</span><span class="text-base-content">{@millis}</span>
    </td>
    """
  end

  attr :icon, :string, required: true
  attr :class, :string, required: true

  defp control_glyph(assigns) do
    ~H"""
    <span class={["size-5 flex shrink-0 items-center justify-center rounded-full", @class]}>
      <.icon name={@icon} class="size-3" />
    </span>
    """
  end

  defp control(%{kind: :started, origin: origin}),
    do: {"icon-play", "bg-success/15 text-success", "bg-base-200", "Started", by(origin)}

  defp control(%{kind: :stopped, reason: :stopped, origin: origin}),
    do: {"icon-square-filled", @muted_glyph, "bg-base-200", "Stopped", by(origin)}

  defp control(%{kind: :stopped, reason: reason}) do
    label = TracingComponents.stop_reason_label(reason)

    if TracingComponents.failure?(reason),
      do: {"icon-square-filled", "bg-warning/20 text-warning", "bg-warning/10", "Stopped", label},
      else: {"icon-square-filled", @muted_glyph, "bg-base-200", "Stopped", label}
  end

  defp control(%{kind: :dropped, count: count}),
    do:
      {"icon-circle-alert", "bg-warning/20 text-warning", "bg-warning/10",
       TracingComponents.count(count, "event", "events") <> " dropped", nil}

  defp control(%{kind: :evicted}),
    do:
      {"icon-info", "bg-info/15 text-info", "bg-info/10", "Older events evicted",
       "only the newest #{@kept_traces} stay in memory"}

  defp by(:ui), do: "by UI"
  defp by(:mcp), do: "by MCP"
  defp by(_origin), do: nil

  defp glyph(:call), do: "icon-arrow-right"
  defp glyph(:return), do: "icon-arrow-left"
  defp glyph(:exception), do: "icon-x"

  defp glyph_class(:call), do: "text-base-content/50"
  defp glyph_class(:return), do: "text-success"
  defp glyph_class(:exception), do: "text-error"

  defp term_class(:exception), do: "text-error"
  defp term_class(_type), do: "text-base-content"

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

  defp format_term(term), do: Formatters.format_term(term, limit: 20, printable_limit: @row_cap)

  defp cap(text) do
    if String.length(text) > @row_cap,
      do: String.slice(text, 0, @row_cap) <> "…",
      else: text
  end

  defp tip_terms(entry) do
    terms = labelled_terms(entry)
    max_lines = max(2, div(@tip_lines, max(length(terms), 1)))
    Enum.map(terms, fn {label, term} -> tip_term(label, term, max_lines) end)
  end

  defp labelled_terms(%{type: :call, args: args}) when is_list(args),
    do: Enum.with_index(args, fn arg, index -> {Integer.to_string(index + 1), arg} end)

  defp labelled_terms(%{type: :call}), do: []

  defp labelled_terms(%{type: :exception, value: {class, reason}}),
    do: [{Formatters.format_term(class), reason}]

  defp labelled_terms(%{value: value}), do: [{nil, value}]

  defp tip_term(label, term, max_lines) do
    lines =
      term
      |> Formatters.format_term(limit: 50, printable_limit: 256, pretty: true, width: @tip_width)
      |> String.split("\n")

    {label, lines |> Enum.take(max_lines) |> Enum.join("\n"), length(lines) > max_lines}
  end

  defp process_label(name) when is_atom(name) and name not in [nil, :undefined],
    do: Formatters.format_term(name)

  defp process_label({_module, _function, _arity} = mfa), do: Formatters.format_mfa(mfa)
  defp process_label(_label), do: nil

  defp type_label(:call), do: "Call"
  defp type_label(:return), do: "Return"
  defp type_label(:exception), do: "Exception"

  defp plain?(%{type: :call, args: args}) when is_list(args), do: false
  defp plain?(%{type: type}), do: type != :return

  defp format_at(at) do
    at
    |> datetime()
    |> Calendar.strftime("%H:%M:%S.%f")
  end

  defp full_at(at) do
    at
    |> datetime()
    |> Calendar.strftime("%a %-d %b %Y, %H:%M:%S.%f UTC")
  end

  defp datetime(at) do
    at
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.truncate(:millisecond)
  end

  defp tip_meta(entry) do
    [type_label(entry.type), format_duration(entry[:duration_us])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp format_duration(nil), do: nil
  defp format_duration(us) when us < 1_000, do: "#{us} µs"

  defp format_duration(us) when us < 10_000,
    do: :erlang.float_to_binary(us / 1_000, decimals: 2) <> " ms"

  defp format_duration(us) when us < 100_000,
    do: :erlang.float_to_binary(us / 1_000, decimals: 1) <> " ms"

  defp format_duration(us), do: Formatters.format_integer(round(us / 1_000)) <> " ms"

  defp footer(%Session{traces: 0}, _trace_rows, _oldest_seq, _new_count), do: "No traces yet"

  defp footer(session, trace_rows, _oldest_seq, new_count) when new_count > 0,
    do:
      "#{Formatters.format_integer(trace_rows)} of #{Formatters.format_integer(session.traces)} traces shown"

  defp footer(session, trace_rows, oldest_seq, _new_count) when oldest_seq > 0,
    do:
      "Newest #{Formatters.format_integer(trace_rows)} of #{Formatters.format_integer(session.traces)} traces"

  defp footer(%Session{save: false, traces: traces}, trace_rows, _oldest_seq, _new_count)
       when trace_rows < traces,
       do:
         "All #{Formatters.format_integer(trace_rows)} kept events shown · #{Formatters.format_integer(traces)} traced"

  defp footer(session, _trace_rows, _oldest_seq, _new_count),
    do: "All #{TracingComponents.count(session.traces, "trace", "traces")} shown"
end

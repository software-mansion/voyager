defmodule VoyagerWeb.Components.TracingComponents do
  @moduledoc """
  Presentation shared by every surface that shows a tracing session: its tone and state
  labels for the shell indicator, the traced MFA, and the configured parameters as chips,
  a table, or the differences from the previous configuration. Also the session page's
  own pieces: the session bar, its empty state and the confirm modal.
  """

  use VoyagerWeb, :component

  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Session
  alias VoyagerWeb.Formatters
  alias VoyagerWeb.TermFormatter

  @spec tone(Session.t(), node() | nil) :: :running | :other_node | :failed | :open
  def tone(session, connected_node \\ nil)
  def tone(%Session{status: :running}, _connected_node), do: :running

  def tone(%Session{node: node}, connected_node)
      when not is_nil(node) and not is_nil(connected_node) and node != connected_node,
      do: :other_node

  def tone(%Session{status: :stopped, stop_reason: reason}, _connected_node),
    do: if(failure?(reason), do: :failed, else: :open)

  def tone(_session, _connected_node), do: :open

  @doc "Whether a stop reason means the run ended on an error rather than a limit or a request."
  @spec failure?(Voyager.Services.Tracer.stop_reason()) :: boolean()
  def failure?({:tracer_down, _reason}), do: true
  def failure?(reason), do: reason in [:node_down, :write_failed]

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
  def format_elapsed(seconds) do
    padded =
      seconds
      |> rem(60)
      |> Integer.to_string()
      |> String.pad_leading(2, "0")

    "#{div(seconds, 60)}:#{padded}"
  end

  @spec traced_mfa(Config.t()) :: String.t()
  def traced_mfa(%Config{module: module, function: function, arity: arity}),
    do: TermFormatter.format_mfa_pattern(module, function, arity)

  @doc "`traced_mfa/1` split into the module with its separator and the `function/arity`."
  @spec traced_mfa_parts(Config.t()) :: {String.t(), String.t()}
  def traced_mfa_parts(%Config{module: module, function: function, arity: arity}),
    do: TermFormatter.mfa_pattern_parts(module, function, arity)

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
      {:capture, "Capture", capture_chip(config)},
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

  @doc "The parameters that differ from `previous`; the traced MFA when there is none."
  attr :config, Config, required: true
  attr :previous, Config, default: nil

  def config_changes(%{previous: nil} = assigns) do
    ~H"""
    {traced_mfa(@config)}
    """
  end

  def config_changes(assigns) do
    assigns =
      assign(assigns, :rows, Enum.filter(config_rows(assigns.config, assigns.previous), & &1.old))

    ~H"""
    <span :if={@rows == []}>no changes</span>
    <span :for={{row, index} <- Enum.with_index(@rows)}>
      {if index > 0, do: " · "}{row.label}
      <span class="text-base-content/40 line-through">{row.old}</span>
      → <span class="text-base-content font-semibold">{row.value}</span>
    </span>
    """
  end

  attr :trace_session, Session, required: true
  attr :mode, :atom, required: true
  attr :pending?, :boolean, required: true
  attr :show_back_arrow, :boolean, required: true
  attr :connected_node, :atom, required: true
  attr :stats, :list, default: []
  attr :on_stop, :string, required: true
  attr :on_start, :string, required: true
  attr :on_load, :string, required: true
  attr :on_unload, :string, required: true
  attr :on_delete, :string, required: true

  def session_bar(assigns) do
    ~H"""
    <div
      id="session-bar"
      class="card bg-base-100 border-base-200 text-base-content flex-none border shadow-sm"
    >
      <div class="flex items-start gap-3 px-4 py-3">
        <.back_arrow :if={@show_back_arrow} id="session-header-back" />
        <div class="min-w-0 flex-1">
          <.session_status trace_session={@trace_session} mode={@mode} />
          <.session_params trace_session={@trace_session} />
        </div>
        <.action_buttons
          trace_session={@trace_session}
          mode={@mode}
          pending?={@pending?}
          other_node?={tone(@trace_session, @connected_node) == :other_node}
          on_stop={@on_stop}
          on_start={@on_start}
          on_load={@on_load}
          on_unload={@on_unload}
          on_delete={@on_delete}
        />
      </div>
      <div
        :if={@stats != []}
        id="session-stats"
        class="bg-base-200 border-base-200 rounded-b-box grid grid-cols-2 gap-px overflow-hidden border-t lg:grid-cols-5"
      >
        <div
          :for={cell <- @stats}
          id={"stat-#{cell.key}"}
          class="bg-base-100 min-w-0 px-5 py-3 last:col-span-2 lg:last:col-span-1"
        >
          <div class="font-mono tracking-label text-base-content/60 mb-1 text-xs font-semibold uppercase">
            {cell.label}
          </div>
          <.tooltip :if={cell[:tip]} id={"stat-#{cell.key}-tip"} position="bottom" class="w-full">
            <.stat_value cell={cell} tip_id={"stat-#{cell.key}-tip-tip"} />
            <:content>
              <span :if={is_binary(cell.tip)}>{cell.tip}</span>
              <table :if={is_list(cell.tip)} class="font-mono">
                <tr :for={{label, value} <- cell.tip}>
                  <td class="text-base-content/60 py-0.5 pr-4">{label}</td>
                  <td class="py-0.5 text-right">{value}</td>
                </tr>
              </table>
            </:content>
          </.tooltip>
          <.stat_value :if={!cell[:tip]} cell={cell} />
        </div>
      </div>
    </div>
    """
  end

  attr :cell, :map, required: true
  attr :tip_id, :string, default: nil

  defp stat_value(assigns) do
    ~H"""
    <div class="w-full" tabindex={@tip_id && "0"} aria-describedby={@tip_id}>
      <div class="min-h-6 flex items-baseline gap-1.5">
        <span class={[
          "truncate text-base font-semibold",
          !@cell[:prose] && "font-mono tabular-nums",
          @cell[:tone]
        ]}>
          {@cell.value}
        </span>
        <span :if={@cell[:unit]} class="font-mono text-base-content/60 shrink-0 text-xs">
          {@cell.unit}
        </span>
        <span
          :if={@cell[:spark]}
          aria-hidden="true"
          class="ml-auto flex h-5 items-end gap-0.5 self-center"
        >
          <span
            :for={height <- @cell.spark}
            class="bg-primary w-0.75 rounded-xs opacity-55 last:opacity-100"
            style={"height: #{height}%"}
          ></span>
        </span>
      </div>
      <div :if={@cell[:bar]} class="bg-base-content/10 mt-2 flex h-1 overflow-hidden rounded-full">
        <span
          :for={{fill, width} <- @cell.bar}
          class={["block h-full transition-all duration-700", fill]}
          style={"width: #{width}%"}
        ></span>
      </div>
    </div>
    """
  end

  defp chips(%Session{config: nil, save: save}),
    do: [{:storage, "Storage", if(save, do: "Saved", else: "Not saved")}]

  defp chips(%Session{config: config}), do: config_chips(config)

  defp status_class(session) do
    case tone(session) do
      :running -> "badge-soft badge-success"
      :failed -> "badge-soft badge-warning"
      :open -> "badge-ghost"
    end
  end

  defp meta(session, :saved), do: recorded(session.started_at, session.stopped_at)
  defp meta(%Session{config: nil}, _mode), do: "Active in tracer · no parameters yet"
  defp meta(%Session{status: :idle}, _mode), do: "Active in tracer · not started"

  defp meta(%Session{status: :running, run_started_at: at}, _mode),
    do: "Active in tracer · run started #{Formatters.format_time(at)} UTC"

  defp meta(%Session{stopped_at: %DateTime{} = at}, _mode),
    do: "Active in tracer · stopped #{Formatters.format_time(at)} UTC"

  defp meta(_session, _mode), do: "Active in tracer · stopped"

  defp recorded(%DateTime{} = from, %DateTime{} = to) do
    if DateTime.to_date(from) == DateTime.to_date(to),
      do: "Recorded #{day(from)} · #{clock(from)}–#{clock(to)} UTC",
      else: "Recorded #{day(from)} #{clock(from)} – #{day(to)} #{clock(to)} UTC"
  end

  defp recorded(%DateTime{} = from, nil), do: "Recorded #{day(from)} · #{clock(from)} UTC"
  defp recorded(nil, _to), do: "Never run"

  defp day(at), do: Calendar.strftime(at, "%a %-d %b")
  defp clock(at), do: Calendar.strftime(at, "%H:%M")

  attr :trace_session, Session, required: true
  attr :mode, :atom, required: true

  defp session_status(assigns) do
    ~H"""
    <div class="flex min-w-0 items-center gap-2 text-xs">
      <span
        id="session-status"
        data-tone={tone(@trace_session)}
        class={["badge badge-sm shrink-0 gap-1.5 font-semibold", status_class(@trace_session)]}
      >
        <span class="size-1.5 relative flex">
          <span
            :if={@trace_session.status == :running}
            class="bg-success size-full absolute inline-flex animate-ping rounded-full opacity-75"
          ></span>
          <span class={[
            "size-1.5 relative inline-flex rounded-full",
            tone_class(tone(@trace_session), :dot)
          ]}></span>
        </span>
        {String.capitalize(state(@trace_session))}
      </span>
      <span
        :if={@mode == :saved}
        id="session-saved"
        class="badge badge-sm badge-outline border-base-300 text-base-content/70 shrink-0 font-medium"
      >
        Saved
      </span>
      <span id="session-meta" class="text-base-content/60 truncate">
        {meta(@trace_session, @mode)}
      </span>
    </div>
    """
  end

  attr :trace_session, Session, required: true

  defp session_params(assigns) do
    ~H"""
    <.tooltip
      id="session-params"
      position="bottom"
      class="mt-1.5 flex w-fit min-w-0 max-w-full flex-wrap items-center gap-x-3 gap-y-1.5"
    >
      <.session_title config={@trace_session.config} />
      <span
        :for={{key, label, value} <- chips(@trace_session)}
        id={"session-chip-#{key}"}
        class="border-base-300 bg-base-200 flex min-w-0 max-w-full items-center gap-1.5 rounded-lg border px-2 py-0.5"
      >
        <span class="font-mono tracking-label text-base-content/50 shrink-0 text-xs font-semibold uppercase">
          {label}
        </span>
        <span class="font-mono text-base-content/90 truncate text-xs">{value}</span>
      </span>
      <:content>
        <.config_table :if={@trace_session.config} config={@trace_session.config} />
        <span :if={!@trace_session.config}>No parameters yet</span>
      </:content>
    </.tooltip>
    """
  end

  attr :config, Config, default: nil

  defp session_title(%{config: nil} = assigns) do
    ~H"""
    <h1 id="session-mfa" class="text-base-content text-base font-semibold">New session</h1>
    """
  end

  defp session_title(assigns) do
    {module, function} = traced_mfa_parts(assigns.config)
    assigns = assign(assigns, module: module, function: function)

    ~H"""
    <h1
      id="session-mfa"
      tabindex="0"
      class="font-mono text-base-content min-w-0 truncate text-base font-semibold"
    >
      <span class="text-base-content/50 font-medium">{@module}</span>{@function}
    </h1>
    """
  end

  attr :trace_session, Session, required: true
  attr :mode, :atom, required: true
  attr :pending?, :boolean, required: true
  attr :other_node?, :boolean, required: true
  attr :on_stop, :string, required: true
  attr :on_start, :string, required: true
  attr :on_load, :string, required: true
  attr :on_unload, :string, required: true
  attr :on_delete, :string, required: true

  defp action_buttons(assigns) do
    ~H"""
    <div class="flex shrink-0 flex-col-reverse items-end gap-2 lg:flex-row lg:items-center">
      <.action_button
        :if={@mode == :active and @trace_session.status != :running}
        id="session-unload"
        icon="icon-log-out"
        label="Unload from tracer"
        phx-click={@on_unload}
        disabled={@pending?}
      />
      <.action_button
        :if={@mode == :saved}
        id="session-load"
        icon="icon-log-in"
        label="Load into tracer"
        phx-click={@on_load}
        disabled={@pending?}
      />
      <.action_button
        :if={@mode == :active and @trace_session.config}
        id="session-edit"
        icon="icon-pencil"
        label="Edit"
        aria-disabled="true"
        class="md:min-w-24"
      >
        <:tip>
          {if @trace_session.status == :running,
            do: "Stop the session to edit its parameters",
            else: "Editing parameters is not available yet"}
        </:tip>
      </.action_button>
      <.action_button
        :if={@mode == :active and @trace_session.status == :running}
        id="session-stop"
        icon="icon-square-filled"
        label="Stop"
        phx-click={@on_stop}
        disabled={@pending?}
        class="btn-soft btn-error md:min-w-24"
      />
      <.action_button
        :if={@mode == :active and @trace_session.status != :running and @other_node?}
        id={if @trace_session.status == :stopped, do: "session-resume", else: "session-start"}
        tip_id="session-run-tip"
        icon="icon-play"
        label={if @trace_session.status == :stopped, do: "Resume", else: "Start"}
        aria-disabled="true"
        class="btn-primary md:min-w-24"
      >
        <:tip>
          Traced on <span class="font-mono">{@trace_session.node}</span>.
          Connect to that node to run this session.
        </:tip>
      </.action_button>
      <.action_button
        :if={@mode == :active and @trace_session.status == :stopped and not @other_node?}
        id="session-resume"
        icon="icon-play"
        label="Resume"
        phx-click={@on_start}
        disabled={@pending?}
        class="btn-primary md:min-w-24"
      />
      <.action_button
        :if={@mode == :active and @trace_session.status == :idle and not @other_node?}
        id="session-start"
        icon="icon-play"
        label="Start"
        phx-click={@on_start}
        disabled={@pending? or is_nil(@trace_session.config)}
        class="btn-primary md:min-w-24"
      />
      <.action_button
        :if={@mode == :saved}
        id="session-delete"
        icon="icon-trash"
        label="Delete session"
        icon_only
        phx-click={@on_delete}
        disabled={@pending?}
        class="btn-ghost text-base-content/60 hover:bg-error/10 hover:text-error"
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :tip_id, :string, default: nil, doc: "the tooltip's id; defaults to `<id>-tip`"
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :icon_only, :boolean, default: false, doc: "keeps the label in the tooltip at every width"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled)

  slot :tip, doc: "shown at every width in place of the label"

  defp action_button(assigns) do
    assigns = assign(assigns, :tip_id, assigns.tip_id || "#{assigns.id}-tip")

    ~H"""
    <.tooltip
      id={@tip_id}
      position="bottom"
      tip_class={if(@tip == [] and not @icon_only, do: "md:hidden")}
    >
      <button
        type="button"
        id={@id}
        class={["btn btn-sm", if(@icon_only, do: "btn-square", else: "max-md:btn-square"), @class]}
        {@rest}
      >
        <.icon name={@icon} class="size-3.5" />
        <span class={if @icon_only, do: "sr-only", else: "sr-only md:not-sr-only"}>{@label}</span>
      </button>
      <:content>{if @tip == [], do: @label, else: render_slot(@tip)}</:content>
    </.tooltip>
    """
  end

  def empty_state(assigns) do
    ~H"""
    <div
      id="session-empty"
      class="card bg-base-100 border-base-200 flex min-h-0 flex-1 flex-col items-center justify-center gap-3 border shadow-sm"
    >
      <.icon name="icon-binoculars" class="text-base-content/60 size-8" />
      <div class="text-center">
        <p class="text-base-content font-semibold">Nothing to trace yet</p>
        <p class="text-base-content/70 mt-0.5 text-sm">
          Pick a function and at least one limit to start this session.
        </p>
      </div>
      <button type="button" id="session-set-parameters" disabled class="btn btn-primary btn-sm">
        <.icon name="icon-pencil" class="size-3.5" /> Set parameters
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :confirm_label, :string, required: true
  attr :on_confirm, :string, required: true
  attr :on_cancel, :string, required: true
  slot :inner_block, required: true

  def confirm_modal(assigns) do
    ~H"""
    <div
      id={@id}
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-title"}
      phx-window-keydown={@on_cancel}
      phx-key="Escape"
      class="modal modal-open"
    >
      <.focus_wrap
        id={"#{@id}-box"}
        phx-mounted={JS.focus_first()}
        class="modal-box border-base-300 max-w-md border shadow-2xl"
      >
        <h2 id={"#{@id}-title"} class="text-base-content text-lg font-semibold tracking-tight">
          {@title}
        </h2>
        {render_slot(@inner_block)}
        <div class="modal-action">
          <button type="button" id={"#{@id}-cancel"} phx-click={@on_cancel} class="btn btn-ghost">
            Cancel
          </button>
          <button
            type="button"
            id={"#{@id}-confirm"}
            phx-click={@on_confirm}
            class="btn btn-error dark:text-base-100"
          >
            {@confirm_label}
          </button>
        </div>
      </.focus_wrap>
    </div>
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
    scope =
      config.scope
      |> Atom.to_string()
      |> String.capitalize()

    [
      {"Function", traced_mfa(config)},
      {"Processes", processes(config)},
      {"Scope", scope},
      {"Capture", capture(config)},
      {"Returns", returns(config)},
      {"Max events", config.max_events && Formatters.format_integer(config.max_events)},
      {"Max rate", config.max_rate && "#{Formatters.format_integer(config.max_rate)}/s"},
      {"Max time", config.max_time_ms && format_time_limit(config.max_time_ms)}
    ]
    |> Enum.map(fn {label, value} -> {label, value || "None"} end)
  end

  defp processes(%Config{processes: :all}), do: "All processes"
  defp processes(%Config{processes: :existing}), do: "Existing processes"
  defp processes(%Config{processes: :new}), do: "New processes"
  defp processes(%Config{processes: :pids, pids: pids}), do: Enum.join(pids, ", ")

  defp capture(%Config{capture: :args} = config), do: "Args " <> budget_cap(config)
  defp capture(_config), do: "Arity"

  defp returns(%Config{return_trace: true} = config), do: "Traced " <> budget_cap(config)
  defp returns(_config), do: "Not traced"

  defp capture_chip(%Config{return_trace: false} = config), do: capture(config)
  defp capture_chip(%Config{capture: :args} = config), do: capture(config) <> " + returns"
  defp capture_chip(config), do: "Arity + returns " <> budget_cap(config)

  defp budget_cap(%Config{budget: budget}), do: "≤ #{Formatters.format_integer(budget)}"

  defp format_time_limit(ms) when rem(ms, 1_000) != 0, do: "#{Formatters.format_integer(ms)} ms"
  defp format_time_limit(ms) when rem(ms, 60_000) != 0, do: "#{div(ms, 1_000)} s"
  defp format_time_limit(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)} min"
  defp format_time_limit(ms), do: "#{div(ms, 3_600_000)} h"

  @spec count(non_neg_integer(), String.t(), String.t()) :: String.t()
  def count(1, singular, _plural), do: "1 #{singular}"
  def count(n, _singular, plural), do: "#{Formatters.format_integer(n)} #{plural}"
end

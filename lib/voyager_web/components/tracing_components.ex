defmodule VoyagerWeb.Components.TracingComponents do
  @moduledoc """
  Presentation shared by every surface that shows a tracing session: its tone and state
  labels for the shell indicator, the traced MFA, and the configured parameters as chips,
  a table, or the differences from the previous configuration.
  """

  use VoyagerWeb, :component

  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Session
  alias VoyagerWeb.Formatters

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
  def format_elapsed(seconds) do
    padded =
      seconds
      |> rem(60)
      |> Integer.to_string()
      |> String.pad_leading(2, "0")

    "#{div(seconds, 60)}:#{padded}"
  end

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
      {"Returns", if(config.return_trace, do: "Traced", else: "Not traced")},
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

  defp capture(%Config{capture: :args, budget: budget}),
    do: "Args ≤ #{Formatters.format_integer(budget)}"

  defp capture(_config), do: "Arity"

  defp format_time_limit(ms) when rem(ms, 1_000) != 0, do: "#{Formatters.format_integer(ms)} ms"
  defp format_time_limit(ms) when rem(ms, 60_000) != 0, do: "#{div(ms, 1_000)} s"
  defp format_time_limit(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)} min"
  defp format_time_limit(ms), do: "#{div(ms, 3_600_000)} h"

  defp count(1, singular, _plural), do: "1 #{singular}"
  defp count(n, _singular, plural), do: "#{Formatters.format_integer(n)} #{plural}"
end

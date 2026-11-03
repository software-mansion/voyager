defmodule VoyagerWeb.Components.TracingComponents do
  @moduledoc false

  use VoyagerWeb, :component

  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Session

  @spec tone(Session.t(), node() | nil) :: :running | :other_node | :failed | :open
  def tone(session, connected_node \\ nil)
  def tone(%Session{status: :running}, _connected_node), do: :running

  def tone(%Session{node: node}, connected_node)
      when not is_nil(connected_node) and node != connected_node,
      do: :other_node

  def tone(%Session{status: :stopped, stop_reason: reason}, _connected_node)
      when reason in [:node_down, :write_failed],
      do: :failed

  def tone(%Session{status: :stopped, stop_reason: {:tracer_down, _reason}}, _connected_node),
    do: :failed

  def tone(_session, _connected_node), do: :open

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
end

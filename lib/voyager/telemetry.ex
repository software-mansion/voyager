defmodule Voyager.Telemetry do
  @moduledoc """
  Telemetry supervisor: attaches the event handler and runs periodic system measurements.
  """

  use Supervisor

  alias Voyager.Telemetry.Events
  alias Voyager.Telemetry.Measurements

  @type event() :: Events.event()

  @telemetry_handler Application.compile_env(:voyager, :telemetry, :noop)
  @telemetry_poller_period_ms 30_000

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {Voyager.Telemetry.Handler, telemetry_handler: @telemetry_handler},
      {:telemetry_poller,
       measurements: periodic_measurements(), period: @telemetry_poller_period_ms}
    ]

    children =
      if @telemetry_handler == :export do
        children ++ [Voyager.Telemetry.Export]
      else
        children
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Dispatch an event by string name.

  String name is the dotted event name, e.g. "voyager.node.connect".
  """
  @spec dispatch(String.t(), Keyword.t()) :: :ok | {:error, :unknown_event}
  def dispatch(event_name, opts \\ [])

  def dispatch("voyager.node.connect", []) do
    :telemetry.execute([:voyager, :node, :connect], %{}, %{})
  end

  def dispatch("voyager.node.disconnect", []) do
    :telemetry.execute([:voyager, :node, :disconnect], %{}, %{})
  end

  def dispatch(_event_name, _opts) do
    {:error, :unknown_event}
  end

  @doc "Measurements for `telemetry_poller`."
  @spec periodic_measurements() :: [{module(), atom(), list()}]
  def periodic_measurements do
    [{__MODULE__, :emit_vm_memory, []}]
  end

  @doc false
  @spec emit_vm_memory() :: :ok
  def emit_vm_memory do
    :telemetry.execute([:voyager, :vm, :memory], Measurements.vm_memory(), %{})
  end
end

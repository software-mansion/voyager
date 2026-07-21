defmodule Voyager.Telemetry do
  @moduledoc """
  Telemetry supervisor: attaches the event handler and runs periodic system measurements.
  """

  use Supervisor

  alias Voyager.Telemetry.Events
  alias Voyager.Telemetry.Measurements

  @type event() :: Events.event()

  @telemetry_poller_period_ms 60_000

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    telemetry_handler = Application.get_env(:voyager, :telemetry_handler, :noop)
    telemetry_config = Application.get_env(:voyager, :telemetry_config, [])

    children = [
      {Voyager.Telemetry.Manager,
       telemetry_handler: telemetry_handler, telemetry_config: telemetry_config},
      {:telemetry_poller,
       measurements: periodic_measurements(), period: @telemetry_poller_period_ms}
    ]

    children =
      if telemetry_handler == :export do
        children ++ [{Task.Supervisor, name: Voyager.Telemetry.ExportTaskSupervisor}]
      else
        children
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Dispatch an event by string name.

  ## Options
  - `:measurements` - Measurements to attach to the event.
  - `:metadata` - Metadata to attach to the event.

  String name is the dotted event name, e.g. `"voyager.node.connect"`.
  """
  @spec dispatch!(String.t(), Keyword.t()) :: :ok
  def dispatch!(event_name, opts \\ []) when is_binary(event_name) do
    event_name = Events.name_to_list(event_name)
    measurements = Keyword.get(opts, :measurements, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    if Events.custom_event?(event_name) do
      :telemetry.execute(event_name, measurements, metadata)
    else
      raise ArgumentError, "Unknown event: #{inspect(event_name)}"
    end
  end

  @doc "Periodically collected measurements for `telemetry_poller`."
  @spec periodic_measurements() :: [{module(), atom(), list()}]
  def periodic_measurements do
    [{__MODULE__, :emit_vm_memory, []}]
  end

  @doc false
  def emit_vm_memory do
    :telemetry.execute([:voyager, :vm, :memory], Measurements.vm_memory(), %{})
  end
end

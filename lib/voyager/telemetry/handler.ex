defmodule Voyager.Telemetry.Handler do
  @moduledoc """
  GenServer that attaches a `:telemetry` handler on start and detaches on terminate.

  The handler is passed via `:telemetry_handler` init option from `Voyager.Telemetry`.
  Can be one of:
  - :export
  - :logger
  - :noop
  """

  use GenServer

  alias Voyager.Telemetry.Events

  @callback handle_event(Events.event(), map(), map(), any()) :: :ok

  @handler_id "voyager-telemetry"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    handler_module =
      case Keyword.fetch!(opts, :telemetry_handler) do
        :export -> Voyager.Telemetry.Handler.Export
        :logger -> Voyager.Telemetry.Handler.Logger
        _ -> Voyager.Telemetry.Handler.Noop
      end

    :telemetry.attach_many(@handler_id, Events.events(), &handler_module.handle_event/4, %{})

    {:ok, %{}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
  end
end

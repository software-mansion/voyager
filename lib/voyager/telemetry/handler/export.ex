defmodule Voyager.Telemetry.Handler.Export do
  @moduledoc false

  alias Voyager.Telemetry.Events
  alias Voyager.Telemetry.Export
  alias Voyager.Telemetry.Parser

  @spec handle_event(Events.event(), map(), map(), any()) :: :ok
  def handle_event(event, measurements, metadata, _config) do
    Export.send(%{
      event: Parser.parse_event(event),
      measurements: measurements,
      metadata: Parser.parse_metadata(event, metadata),
      ts: System.system_time(:millisecond)
    })

    :ok
  end
end

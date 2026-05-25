defmodule Voyager.Telemetry.Handler.Export do
  @moduledoc false

  @behaviour Voyager.Telemetry.Handler

  alias Voyager.Telemetry.Export
  alias Voyager.Telemetry.Parser

  @impl true
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

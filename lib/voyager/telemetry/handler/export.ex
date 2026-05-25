defmodule Voyager.Telemetry.Handler.Export do
  @moduledoc false

  alias Voyager.Telemetry.Parser
  alias Voyager.Telemetry.Export

  @spec handle_event(String.t(), map(), map(), map()) :: :ok
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

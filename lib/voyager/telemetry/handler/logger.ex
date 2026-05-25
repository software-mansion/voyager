defmodule Voyager.Telemetry.Handler.Logger do
  @moduledoc false

  alias Voyager.Telemetry.Parser

  require Logger

  @spec handle_event(String.t(), map(), map(), map()) :: :ok
  def handle_event(event, measurements, metadata, _config) do
    Logger.debug("""
    TELEMETRY #{Parser.parse_event(event)}
      measurements: #{inspect(measurements, pretty: true, limit: 50)}
      metadata:     #{Parser.parse_metadata(event, metadata) |> inspect(pretty: true, limit: 50)}
    """)

    :ok
  end
end

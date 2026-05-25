defmodule Voyager.Telemetry.Handler.Noop do
  @moduledoc false

  @behaviour Voyager.Telemetry.Handler

  @impl true
  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end

defmodule Voyager.Telemetry.Handler.Noop do
  @moduledoc false

  @spec handle_event(String.t(), map(), map(), map()) :: :ok
  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end

defmodule Voyager.Telemetry.Handler do
  @moduledoc """
  Behaviour for telemetry handlers.
  """

  alias Voyager.Telemetry.Events

  @callback handle_event(Events.event(), map(), map(), any()) :: :ok

  @handler_id "voyager-telemetry"

  @spec handler_id() :: String.t()
  def handler_id, do: @handler_id
end

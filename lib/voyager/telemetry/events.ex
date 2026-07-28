defmodule Voyager.Telemetry.Events do
  @moduledoc """
  Telemetry event catalog: Phoenix LiveView, periodic system snapshots, and custom Voyager events.
  """

  @type event() :: [atom()]

  @custom_events [
    [:voyager, :node, :connect],
    [:voyager, :node, :disconnect],
    [:voyager, :mcp, :start],
    [:voyager, :mcp, :stop]
  ]

  @system_events [
    [:voyager, :vm, :memory]
  ]

  @phoenix_events [
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :mount, :exception],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_view, :handle_event, :exception],
    [:phoenix, :live_view, :handle_info, :stop],
    [:phoenix, :live_view, :handle_info, :exception]
  ]

  # Emitted by the `anubis_mcp` dependency itself (via `:telemetry.span/3`)
  @mcp_events [
    [:server, :tool_call, :start],
    [:server, :tool_call, :stop],
    [:server, :tool_call, :exception]
  ]

  @all_events @phoenix_events ++ @system_events ++ @custom_events ++ @mcp_events

  @doc """
  Returns telemetry events by type.

  Supported types:
  - `:all` (default)
  - `:phoenix`
  - `:system`
  - `:custom`
  - `:mcp`
  """
  @spec events(:all | :phoenix | :system | :custom | :mcp) :: [event()]
  def events(type \\ :all)
  def events(:all), do: @all_events
  def events(:phoenix), do: @phoenix_events
  def events(:system), do: @system_events
  def events(:custom), do: @custom_events
  def events(:mcp), do: @mcp_events

  @doc """
  Checks if an event is a custom event.
  """
  @spec custom_event?(event()) :: boolean()
  def custom_event?(event) when is_list(event) do
    event in @custom_events
  end

  @doc "Translates a dotted event name (e.g. `\"voyager.vm.memory\"`) to an atom list."
  @spec name_to_list(String.t()) :: [atom()]
  def name_to_list(name) when is_binary(name) do
    name
    |> String.split(".", trim: true)
    |> Enum.map(&String.to_existing_atom/1)
  end
end

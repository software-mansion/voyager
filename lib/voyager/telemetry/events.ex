defmodule Voyager.Telemetry.Events do
  @moduledoc """
  Telemetry event catalog: Phoenix LiveView, periodic system snapshots, and custom Voyager events.
  """

  @type event() :: [atom()]

  @vm_memory_event [:voyager, :vm, :memory]

  @custom_events [
    [:voyager, :node, :connect],
    [:voyager, :node, :disconnect]
  ]

  @system_events [@vm_memory_event]

  @phoenix_events [
    [:phoenix, :live_view, :mount, :start],
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :mount, :exception],
    [:phoenix, :live_view, :handle_event, :start],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_view, :handle_event, :exception],
    [:phoenix, :live_view, :handle_info, :start],
    [:phoenix, :live_view, :handle_info, :stop],
    [:phoenix, :live_view, :handle_info, :exception]
  ]

  @all_events @phoenix_events ++ @system_events ++ @custom_events

  @doc """
  Returns telemetry events by type.

  Supported types:
  - `:all` (default)
  - `:phoenix`
  - `:system`
  - `:custom`
  """
  @spec events(:all | :phoenix | :system | :custom) :: [event()]
  def events(type \\ :all)
  def events(:all), do: @all_events
  def events(:phoenix), do: @phoenix_events
  def events(:system), do: @system_events
  def events(:custom), do: @custom_events

  @doc "Translates a dotted event name (e.g. `\"voyager.vm.memory\"`) to an atom list."
  @spec name_to_list(String.t()) :: [atom()]
  def name_to_list(name) when is_binary(name) do
    name
    |> String.split(".", trim: true)
    |> Enum.map(&String.to_existing_atom/1)
  end
end

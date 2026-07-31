defmodule Voyager.Telemetry.Parser do
  @moduledoc """
  Parses telemetry event names and whitelists the measurements and metadata
  collected per event, giving a clean, explicit view into captured telemetry.

  Raw socket structs, stacktraces, session data, and user-supplied params are all excluded.
  """

  alias Voyager.Telemetry.Events

  @doc "Converts an event atom list into a dotted string, e.g. `[:voyager, :vm, :memory]` → `\"voyager.vm.memory\"`."
  @spec parse_event(Events.event()) :: String.t()
  def parse_event(event) do
    Enum.map_join(event, ".", &Atom.to_string/1)
  end

  @doc """
  Whitelists and normalizes measurements for a known events.
  """
  @spec parse_measurements(Events.event(), map()) :: map()

  def parse_measurements([:phoenix, :live_view, _, :stop], m) do
    %{duration_ms: native_to_ms(m[:duration])}
  end

  def parse_measurements([:phoenix, :live_view, _, :exception], m) do
    %{duration_ms: native_to_ms(m[:duration])}
  end

  def parse_measurements([:voyager, :vm, :memory], m) do
    Map.take(m, [:total, :processes, :atom, :ets, :binary, :code, :system])
  end

  def parse_measurements([:voyager, :node, :connect], _m), do: %{}
  def parse_measurements([:voyager, :node, :disconnect], _m), do: %{}
  def parse_measurements([:voyager, :mcp, :start], _m), do: %{}
  def parse_measurements([:voyager, :mcp, :stop], _m), do: %{}

  def parse_measurements([:server, :tool_call, :start], _m), do: %{}

  def parse_measurements([:server, :tool_call, :stop], m) do
    %{duration_ms: native_to_ms(m[:duration])}
  end

  def parse_measurements([:server, :tool_call, :exception], m) do
    %{duration_ms: native_to_ms(m[:duration])}
  end

  def parse_measurements(_event, _m), do: %{}

  @doc """
  Whitelists and normalizes metadata for a known events
  """
  @spec parse_metadata(Events.event(), map()) :: map()

  def parse_metadata([:phoenix, :live_view, _, :stop], %{socket: socket}) do
    %{view: inspect(socket.view)}
  end

  def parse_metadata([:phoenix, :live_view, _, :exception], %{socket: socket} = meta) do
    %{
      view: inspect(socket.view),
      kind: meta[:kind],
      reason: inspect(meta[:reason])
    }
  end

  def parse_metadata([:voyager, :vm, :memory], _meta), do: %{}
  def parse_metadata([:voyager, :node, :connect], meta), do: %{via: meta[:via]}

  def parse_metadata([:voyager, :node, :disconnect], meta) do
    %{reason: meta[:reason]}
  end

  def parse_metadata([:voyager, :mcp, :start], meta), do: %{reason: meta[:reason]}
  def parse_metadata([:voyager, :mcp, :stop], meta), do: %{reason: meta[:reason]}

  def parse_metadata([:server, :tool_call, :start], meta) do
    %{tool: meta[:tool]}
  end

  def parse_metadata([:server, :tool_call, :stop], meta) do
    %{tool: meta[:tool]}
  end

  def parse_metadata([:server, :tool_call, :exception], meta) do
    %{tool: meta[:tool], kind: meta[:kind], reason: inspect(meta[:reason])}
  end

  def parse_metadata(_event, _meta), do: %{}

  defp native_to_ms(nil), do: nil
  defp native_to_ms(native), do: System.convert_time_unit(native, :native, :millisecond)
end

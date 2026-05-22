defmodule Voyager.Telemetry.Parser do
  @moduledoc """
  Parses telemetry event names and keeps only metadata that is used downstream.
  """

  alias Voyager.Telemetry.Events

  @doc "Converts event list into dotted name, e.g. `[:voyager, :vm, :memory]`."
  @spec parse_event(Events.event()) :: String.t()
  def parse_event(event) do
    event
    |> Enum.map_join(".", &Atom.to_string/1)
  end

  @doc "Keeps only metadata used by known event groups."
  @spec parse_metadata(Events.event(), map()) :: map()
  def parse_metadata([:phoenix, :live_view | rest], %{socket: socket} = meta) do
    %{view: inspect(socket.view), uri: to_string(socket.host_uri)}
    |> maybe_put(:event, meta[:event])
    |> maybe_exception(rest, meta)
  end

  def parse_metadata([:voyager | _], meta), do: Map.take(meta, [:node, :reason])

  def parse_metadata(_event, _meta), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_exception(map, [:exception], %{kind: kind, reason: reason}) do
    map
    |> Map.put(:kind, inspect(kind))
    |> Map.put(:reason, inspect(reason))
  end

  defp maybe_exception(map, _rest, _meta), do: map
end

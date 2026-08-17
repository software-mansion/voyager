defmodule Voyager.Telemetry.Parser do
  @moduledoc """
  Parses telemetry event names and whitelists the measurements and metadata
  collected per event, giving a clean, explicit view into captured telemetry.

  Raw socket structs, stacktraces, session data, and user-supplied params are all excluded.
  """

  alias Voyager.Telemetry.Events

  # Connection-failure reasons that carry no sensitive data — safe to export verbatim.
  @safe_reasons ~w(
    not_distributed
    connection_failed
    node_unreachable
    name_type_mismatch
    bad_cookie
    node_connect_failed
    invalid_name_type
    invalid_epmd_response
  )a

  # Tagged reasons whose category is useful but whose payload may embed a host,
  # node name, cookie, raw remote output, or a nested error — keep only the tag.
  @safe_reason_tags ~w(
    invalid_host
    invalid_node_name
    invalid_node_format
    node_not_found
    net_kernel
    net_kernel_stop
    already_started
    connector_crashed
  )a

  # Option keys are a bounded, non-sensitive set — safe to keep alongside the tag.
  @safe_option_keys ~w(ssh_user ssh_host)a

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
  def parse_measurements([:voyager, :node, :connect_failed], _m), do: %{}
  def parse_measurements([:voyager, :node, :disconnect], _m), do: %{}
  def parse_measurements([:voyager, :mcp, :start], _m), do: %{}
  def parse_measurements([:voyager, :mcp, :stop], _m), do: %{}

  def parse_measurements([:anubis_mcp, :server, :tool_call, :start], _m), do: %{}

  def parse_measurements([:anubis_mcp, :server, :tool_call, :stop], m) do
    %{duration_ms: native_to_ms(m[:duration])}
  end

  def parse_measurements([:anubis_mcp, :server, :tool_call, :exception], m) do
    %{duration_ms: native_to_ms(m[:duration])}
  end

  def parse_measurements(_event, _m), do: %{}

  @doc """
  Whitelists and normalizes metadata for a known events
  """
  @spec parse_metadata(Events.event(), map()) :: map()

  def parse_metadata([:phoenix, :live_view, _, :stop], %{socket: socket, event: event}) do
    %{view: inspect(socket.view), event: event}
  end

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

  def parse_metadata([:voyager, :node, :connect], meta) do
    %{connected_via: meta[:connected_via]}
  end

  def parse_metadata([:voyager, :node, :connect_failed], meta) do
    %{connected_via: meta[:connected_via], reason: sanitize_reason(meta[:reason])}
  end

  def parse_metadata([:voyager, :node, :disconnect], meta) do
    %{reason: meta[:reason]}
  end

  def parse_metadata([:voyager, :mcp, :start], meta), do: %{reason: meta[:reason]}
  def parse_metadata([:voyager, :mcp, :stop], meta), do: %{reason: meta[:reason]}

  def parse_metadata([:anubis_mcp, :server, :tool_call, :start], meta) do
    %{tool: meta[:tool]}
  end

  def parse_metadata([:anubis_mcp, :server, :tool_call, :stop], meta) do
    %{tool: meta[:tool]}
  end

  def parse_metadata([:anubis_mcp, :server, :tool_call, :exception], meta) do
    %{tool: meta[:tool], kind: meta[:kind], reason: inspect(meta[:reason])}
  end

  def parse_metadata(_event, _meta), do: %{}

  defp native_to_ms(nil), do: nil
  defp native_to_ms(native), do: System.convert_time_unit(native, :native, :millisecond)

  # Maps a connection-failure reason to a non-sensitive category string. Anything
  # not explicitly allow-listed collapses to "unknown".
  defp sanitize_reason(reason) when is_atom(reason) and reason in @safe_reasons do
    Atom.to_string(reason)
  end

  defp sanitize_reason({:missing_option, key}) when key in @safe_option_keys do
    "missing_option:#{key}"
  end

  defp sanitize_reason(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and
              is_atom(elem(reason, 0)) and elem(reason, 0) in @safe_reason_tags do
    reason |> elem(0) |> Atom.to_string()
  end

  defp sanitize_reason(_reason), do: "unknown"
end

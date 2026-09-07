defmodule Voyager.MCP.Tools.ProcessInfo do
  @moduledoc """
  Returns the runtime details of one process on the connected node.

  `pid` is the textual `"<X.Y.Z>"` form returned by `process_list`. The default
  payload holds only fixed-size attributes and is safe to poll; the unbounded
  ones are fetched only when named in `include` and are truncated on the remote
  node, to `limit` entries and to a term budget. A truncated section reports the
  real length as `total`, whether anything was dropped as `truncated?`, and
  elided subterms as `"$voyager_truncated"`. A section that could not be read
  reports an `error` instead of failing the call. Sizes are in bytes.

  `state` and `messages` are the expensive reads -- the remote has to copy the
  term before truncating it -- so ask for them deliberately, never on a refresh.
  A process that does not handle system messages answers `state` with a timeout.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.MCP.Tools.Remote
  alias Voyager.Pid
  alias Voyager.Services.ProcessInfo
  alias Voyager.Services.ProcessTerm

  @sections ~w(links monitors monitored_by dictionary label state messages)

  schema do
    field :pid, :string,
      required: true,
      description: ~s(Process to inspect, in `"<X.Y.Z>"` form.)

    field :include, {:list, {:enum, @sections}},
      default: [],
      description: "Unbounded attributes to fetch alongside the fixed-size ones."

    field :limit, :integer,
      default: 25,
      min: 1,
      max: 200,
      description: "Maximum entries per included attribute."
  end

  @impl true
  def execute(params, frame) do
    case Pid.parse(params.pid) do
      nil ->
        {:reply, Response.error(Response.tool(), "Malformed pid: #{params.pid}"), frame}

      pid ->
        Remote.reply(&fetch(&1, pid, Enum.uniq(params.include), params.limit), frame)
    end
  end

  defp fetch(node, pid, include, limit) do
    with {:ok, info} <- ProcessInfo.fetch(node, pid) do
      sections =
        Map.new(include, fn section ->
          {key, result} = fetch_section(section, node, pid, limit)
          {key, section_value(result)}
        end)

      {:ok, info |> Map.put(:pid, pid) |> Map.merge(sections)}
    end
  end

  defp fetch_section("links", node, pid, limit),
    do: {:links, ProcessInfo.fetch_links(node, pid, limit)}

  defp fetch_section("monitors", node, pid, limit),
    do: {:monitors, ProcessInfo.fetch_monitors(node, pid, limit)}

  defp fetch_section("monitored_by", node, pid, limit),
    do: {:monitored_by, ProcessInfo.fetch_monitored_by(node, pid, limit)}

  defp fetch_section("dictionary", node, pid, limit),
    do: {:dictionary, ProcessInfo.fetch_dictionary(node, pid, limit)}

  defp fetch_section("label", node, pid, _limit),
    do: {:label, ProcessInfo.fetch_label(node, pid)}

  defp fetch_section("state", node, pid, _limit),
    do: {:state, ProcessTerm.fetch_state(node, pid)}

  defp fetch_section("messages", node, pid, limit),
    do: {:messages, ProcessTerm.fetch_messages(node, pid, limit)}

  defp section_value({:ok, value}), do: value
  defp section_value({:error, reason}), do: %{error: inspect(reason)}
end

defmodule Voyager.MCP.Tools.ProcessInfo do
  @moduledoc """
  Returns one attribute of one process on the connected node.

  `pid` is the textual `"<X.Y.Z>"` form returned by `process_list`. `section`
  picks what to read and every call reads exactly one, so each is rate limited
  on its own. The default, `info`, holds the fixed-size attributes and is safe
  to poll. Collection sections are truncated on the remote node to `limit` entries
  and a term budget; they report the real length as `total`, dropped data as
  `truncated?`, and entries as `items`. `label` and `state` return a single
  term limited by the term budget. Elided subterms use `"$voyager_truncated"`.
  Sizes are in bytes.

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

  @sections ~w(info links monitors monitored_by dictionary label state messages)

  schema do
    field :pid, :string,
      required: true,
      description: ~s(Process to inspect, in `"<X.Y.Z>"` form.)

    field :section, :enum,
      values: @sections,
      default: "info",
      description: "Which attribute to read. One call reads one section."

    field :limit, :integer,
      default: 25,
      min: 1,
      max: 200,
      description: "Maximum entries in the returned section."
  end

  @impl true
  def execute(params, frame) do
    case Pid.parse(params.pid) do
      nil ->
        {:reply, Response.error(Response.tool(), "Malformed pid: #{params.pid}"), frame}

      pid ->
        Remote.reply(&fetch(&1, pid, params.section, params.limit), frame)
    end
  end

  defp fetch(node, pid, "info", _limit) do
    with {:ok, info} <- ProcessInfo.fetch(node, pid) do
      {:ok, Map.put(info, :pid, pid)}
    end
  end

  defp fetch(node, pid, section, limit) do
    {key, result} = fetch_section(section, node, pid, limit)

    with {:ok, value} <- result do
      {:ok, %{:pid => pid, key => value}}
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

end

defmodule Voyager.MCP.Tools.ProcessInfo do
  @moduledoc """
  Returns one attribute of one process on the connected node.

  `pid` is the textual `"<X.Y.Z>"` form returned by `process_list`. `section`
  picks what to read and every call reads exactly one, so each is rate limited
  on its own. The default, `info`, holds the fixed-size attributes and is safe
  to poll.

  Every other section is unbounded and is truncated on the remote node before
  it crosses the wire. `limit` caps how many entries a collection returns
  (`links`, `monitors`, `monitored_by`, `dictionary`, `messages`); `budget`
  caps how big the terms themselves may be, counting one unit per term visited
  -- a binary costs one per byte kept, a fun or bignum its wire size,
  all-or-nothing -- and applies to the sections carrying arbitrary user terms
  (`dictionary`, `label`, `state`, `messages`). Collections report the real
  length as `total`, the kept entries as `items`, and whether anything was
  dropped as `truncated?`; `label` and `state` return a single `term` under
  the same budget. Elided subterms come back as `"$voyager_truncated"`; raise
  `budget` only to fetch the rest of a term that came back truncated. Sizes
  are in bytes.

  `state` and `messages` are the expensive reads -- the remote has to copy the
  term before truncating it -- so ask for them deliberately, never on a refresh.
  A process that does not handle system messages answers `state` with a timeout.
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.Agent
  alias Voyager.MCP.Tools.Remote
  alias Voyager.Pid
  alias Voyager.Services.ProcessInfo
  alias Voyager.Services.ProcessTerm

  @sections ~w(info links monitors monitored_by dictionary label state messages)

  @default_budget Agent.default_budget()

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
      max: 1000,
      description: "Maximum entries in the returned section."

    field :budget, :integer,
      default: @default_budget,
      min: 100,
      description:
        "Term size cap, one unit per term visited. Applies to `dictionary`, `label`, `state` and `messages`."
  end

  @impl true
  def execute(params, frame) do
    case Pid.parse(params.pid) do
      nil ->
        {:reply, Response.error(Response.tool(), "Malformed pid: #{params.pid}"), frame}

      pid ->
        Remote.reply(&fetch(&1, pid, params.section, params.limit, params.budget), frame)
    end
  end

  defp fetch(node, pid, "info", _limit, _budget) do
    with {:ok, info} <- ProcessInfo.fetch(node, pid) do
      {:ok, Map.put(info, :pid, pid)}
    end
  end

  defp fetch(node, pid, section, limit, budget) do
    {key, result} = fetch_section(section, node, pid, limit, budget)

    with {:ok, value} <- result do
      {:ok, %{:pid => pid, key => value}}
    end
  end

  defp fetch_section("links", node, pid, limit, _budget),
    do: {:links, ProcessInfo.fetch_links(node, pid, limit)}

  defp fetch_section("monitors", node, pid, limit, _budget),
    do: {:monitors, ProcessInfo.fetch_monitors(node, pid, limit)}

  defp fetch_section("monitored_by", node, pid, limit, _budget),
    do: {:monitored_by, ProcessInfo.fetch_monitored_by(node, pid, limit)}

  defp fetch_section("dictionary", node, pid, limit, budget),
    do: {:dictionary, ProcessInfo.fetch_dictionary(node, pid, limit, budget)}

  defp fetch_section("label", node, pid, _limit, budget),
    do: {:label, ProcessInfo.fetch_label(node, pid, budget)}

  defp fetch_section("state", node, pid, _limit, budget),
    do: {:state, ProcessTerm.fetch_state(node, pid, budget)}

  defp fetch_section("messages", node, pid, limit, budget),
    do: {:messages, ProcessTerm.fetch_messages(node, pid, limit, budget)}
end

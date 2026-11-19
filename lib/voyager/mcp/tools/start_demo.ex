defmodule Voyager.MCP.Tools.StartDemo do
  @moduledoc """
  Starts Voyager's bundled demo node, `voyager_demo@127.0.0.1`, a local Elixir
  node for trying Voyager when the user has no node of their own at hand. It
  only starts the node: call `connect` with
  `node_name: "voyager_demo@127.0.0.1"` right after it to inspect the demo.

  Voyager connects to one node at a time. Already connected to the demo, the
  result is `connected` and the demo keeps running. Connected to another node,
  this tool refuses and names that node: tell the user, call `disconnect` once
  they agree (it ends the session they may be looking at), then call
  `start_demo` again.

  The demo stops when Voyager disconnects from it, connects to another node, or
  is not connected to it within 5 minutes; call `start_demo` again for a new
  one. It runs only in the Voyager desktop app.

  Once connected, explore it with:
  - `node_info`: OTP and Elixir versions, memory, process and port counts
  - `process_list` / `process_info`: the `supervision_tree_demo` application,
    with `SupervisionTreeDemo.StuckMailbox` (200 messages queued in a stalled
    process), `SupervisionTreeDemo.LargeState` (a large GenServer state),
    `SupervisionTreeDemo.Hub` (links, monitors, a port and a socket) and
    workers under dynamic, task and nested supervisors
  - `ets_list` / `ets_read_table_chunk` / `ets_search_table`: tables of every
    type and protection, e.g. `kv_set`, `users_ordered`, `bag_events`,
    `dup_bag`, `protected_config`, `huge_records`, `all_elixir_types`
  - `module_list`: the demo modules, `SupervisionTreeDemo.*` and `EtsDemo`
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.NodeSession
  alias Voyager.Services.DemoNode

  schema do
  end

  @impl true
  def execute(_params, frame) do
    {:reply, start(NodeSession.current()), frame}
  end

  defp start(nil) do
    case DemoNode.start() do
      {:ok, %{node_name: node}} ->
        Response.json(Response.tool(), %{
          status: "started",
          node: node,
          message: "Call `connect` with node_name #{inspect(node)} now."
        })

      {:error, :unavailable} ->
        Response.error(Response.tool(), "The demo node runs only in the Voyager desktop app")

      {:error, _reason} ->
        Response.error(Response.tool(), "Could not start the demo node")
    end
  end

  defp start(session) do
    if session.node_name == DemoNode.node_name() do
      Response.json(Response.tool(), %{status: "connected", node: session.node_name})
    else
      Response.error(
        Response.tool(),
        "Connected to #{session.node_name}, call `disconnect` first, then `start_demo` again"
      )
    end
  end
end

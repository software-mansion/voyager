defmodule Voyager.MCP.Tools.ListConnections do
  @moduledoc """
  Lists the node connections saved in Voyager, pinned first, then most recently
  used. Call it before `connect` when the user names a node or environment
  ("staging", "the shop node") to find its `id`.

  `needs_user_input` is true when the cookie (or, for SSH password auth, the
  password) is not stored: `connect` then opens Voyager for the user to type it.
  `connected` marks the row Voyager is connected to right now. Secrets are never
  returned.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.MCP.Tools.Connect
  alias Voyager.NodeSession
  alias Voyager.Queries.Connections, as: ConnectionQueries
  alias Voyager.Queries.SshConnections, as: SshConnectionQueries
  alias Voyager.Schemas.Connection
  alias Voyager.Schemas.SshConnection
  alias Voyager.Services.SavedConnections

  schema do
  end

  @impl true
  def execute(_params, frame) do
    session = NodeSession.current()

    connections =
      (ConnectionQueries.all() ++ SshConnectionQueries.all())
      |> Enum.sort_by(&{&1.pinned, DateTime.to_unix(&1.last_connected_at)}, :desc)
      |> Enum.map(&row(&1, session))

    {:reply, Response.json(Response.tool(), %{connections: connections}), frame}
  end

  defp row(saved, session) do
    %{
      id: Connect.id(saved),
      node_name: saved.node_name,
      name_type: saved.name_type,
      pinned: saved.pinned,
      last_connected_at: saved.last_connected_at,
      connected: SavedConnections.connected?(saved, session),
      needs_user_input: not SavedConnections.ready?(saved)
    }
    |> put_ssh(saved)
  end

  defp put_ssh(row, %Connection{}), do: row

  defp put_ssh(row, %SshConnection{} = c) do
    Map.put(row, :ssh, %{
      user: c.ssh_user,
      host: c.ssh_host,
      port: c.ssh_port,
      epmd_port: c.epmd_port,
      auth_method: c.auth_method
    })
  end
end

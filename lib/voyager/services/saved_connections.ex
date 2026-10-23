defmodule Voyager.Services.SavedConnections do
  @moduledoc """
  Connects saved direct and SSH connections with their stored secrets, for callers
  that cannot ask the user for them (the tray, MCP).
  """

  alias Voyager.Actions.Connections, as: ConnectionActions
  alias Voyager.Actions.SshConnections, as: SshConnectionActions
  alias Voyager.NodeSession
  alias Voyager.NodeSession.Connectors.Distribution
  alias Voyager.NodeSession.Connectors.Ssh, as: SshConnector
  alias Voyager.NodeSession.Session
  alias Voyager.Schemas.Connection
  alias Voyager.Schemas.SshConnection

  @type saved :: Connection.t() | SshConnection.t()

  @doc "Whether every secret `connect/1` needs is stored."
  @spec ready?(saved()) :: boolean()
  def ready?(%Connection{cookie: nil}), do: false
  def ready?(%Connection{}), do: true

  def ready?(%SshConnection{cookie: nil}), do: false
  def ready?(%SshConnection{auth_method: :password, password: nil}), do: false
  def ready?(%SshConnection{}), do: true

  @doc "Whether `session` is a live connection to the same node over the same route."
  @spec connected?(saved(), Session.t() | nil) :: boolean()
  def connected?(%Connection{node_name: name}, %Session{node_name: name, connector: Distribution}),
      do: true

  def connected?(
        %SshConnection{node_name: name, ssh_user: user, ssh_host: host} = c,
        %Session{node_name: name, meta: %{ssh_user: user, ssh_host: host} = meta}
      )
      when c.ssh_port == meta.ssh_port and c.epmd_port == meta.epmd_port,
      do: true

  def connected?(_saved, _session), do: false

  @spec connect(saved()) :: :ok | {:error, term()}
  def connect(%Connection{} = c) do
    with :ok <- NodeSession.connect(c.node_name, c.cookie, name_type: c.name_type) do
      ConnectionActions.upsert_connected(c.node_name, name_type: c.name_type)
      :ok
    end
  end

  def connect(%SshConnection{} = c) do
    auth = if c.auth_method == :password, do: {:password, c.password}, else: :agent

    opts = [
      ssh_user: c.ssh_user,
      ssh_host: c.ssh_host,
      auth: auth,
      ssh_port: c.ssh_port,
      epmd_port: c.epmd_port,
      name_type: c.name_type
    ]

    with :ok <- NodeSession.connect_via(SshConnector, c.node_name, c.cookie, opts) do
      SshConnectionActions.upsert_connected(c.ssh_user, c.ssh_host, c.ssh_port, c.node_name,
        name_type: c.name_type,
        auth_method: c.auth_method,
        epmd_port: c.epmd_port
      )

      :ok
    end
  end
end

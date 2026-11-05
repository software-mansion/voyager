defmodule Voyager.MCP.Tools.ListSshConfigHosts do
  @moduledoc """
  Lists the hosts in the user's SSH config: the file imported in Voyager's SSH
  form, or `~/.ssh/config` when none is imported. Call it when the node is not
  in `list_connections`.

  Show the hosts and let the user pick one instead of guessing from the alias.
  Hosts have no `id`: pass their fields to `connect`, plus a `node_name` only if
  the user gave one. Voyager asks for a missing `node_name` or a `null`
  `ssh_user` in its connect form.

  Only `Host`, `HostName`, `User`, `Port`, `IdentityFile`, `IdentityAgent` and
  `Include` are read. Settings such as `ProxyJump`, `ProxyCommand` and `Match`
  are ignored, so a host that needs them can still fail to connect. An SSH
  config does not state an auth method and `connect` defaults to `agent`: pass
  `auth_method: "key"` for `key_path` to take effect.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.NodeSession.ConnectError
  alias Voyager.Services.SSH.Config
  alias Voyager.Settings

  schema do
  end

  @impl true
  def execute(_params, frame) do
    path = Config.config_path(Settings.get(:ssh_config_path))

    response =
      case Config.read(path) do
        {:ok, %{hosts: hosts}} ->
          Response.json(Response.tool(), %{hosts: Enum.map(hosts, &row/1)})

        {:error, reason} ->
          Response.error(Response.tool(), "#{ConnectError.message(reason)}: #{path}")
      end

    {:reply, response, frame}
  end

  defp row(host) do
    %{
      alias: host.alias,
      ssh_host: host.host_name || host.alias,
      ssh_user: host.user,
      ssh_port: host.port || 22,
      key_path: List.first(host.identity_files),
      agent_socket_path: agent_socket_path(host.identity_agent)
    }
  end

  defp agent_socket_path(:none), do: nil
  defp agent_socket_path(path), do: path
end

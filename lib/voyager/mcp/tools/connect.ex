defmodule Voyager.MCP.Tools.Connect do
  @moduledoc """
  Connects Voyager to a node so the other tools can inspect it. Pass a saved
  `connection_id` from `list_connections`, or describe a node that is not saved
  with `node_name` (plus `ssh_user` and `ssh_host` to tunnel through SSH).

  Secrets never pass through this tool, so never ask the user to paste a cookie or
  password into the chat. A saved connection with its secrets stored connects
  right away. Otherwise Voyager opens its connect form pre-filled and the result
  is `awaiting_user`: ask the user to finish in Voyager, then call `connect` again
  with the same arguments once they confirm. Calling it for the node Voyager is
  already connected to returns `connected`. Only one node can be connected at a
  time: call `disconnect` first to switch.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Voyager.NodeSession
  alias Voyager.NodeSession.ConnectError
  alias Voyager.ProxyEpmd
  alias Voyager.Queries.Connections, as: ConnectionQueries
  alias Voyager.Queries.SshConnections, as: SshConnectionQueries
  alias Voyager.Schemas.Connection
  alias Voyager.Schemas.SshConnection
  alias Voyager.Services.SavedConnections

  @name_types %{"longnames" => :longnames, "shortnames" => :shortnames}
  @auth_methods %{"agent" => :agent, "password" => :password, "key" => :key}

  schema do
    field :connection_id, :string,
      description: ~s(Saved connection `id` from `list_connections`, e.g. "ssh:5".)

    field :node_name, :string,
      description: ~s(Full node name such as "shop@10.0.4.12", for a node with no saved `id`.)

    field :name_type, :enum,
      values: Map.keys(@name_types),
      default: "longnames",
      description:
        "`longnames` for a node started with `--name` (\"shop@127.0.0.1\"), " <>
          "`shortnames` for `--sname` (\"shop@localhost\")."

    field :ssh_user, :string, description: "SSH user. Set with `ssh_host` to tunnel through SSH."
    field :ssh_host, :string, description: "SSH host the node runs on."
    field :ssh_port, :integer, default: 22, min: 1, max: 65_535, description: "SSH port."

    field :epmd_port, :integer,
      default: 4369,
      min: 1,
      max: 65_535,
      description: "epmd port on the SSH host."

    field :auth_method, :enum,
      values: Map.keys(@auth_methods),
      default: "agent",
      description:
        "SSH auth: `agent` uses the local ssh-agent, `password` is typed in Voyager, " <>
          "`key` reads `key_path` (its passphrase, if any, is typed in Voyager)."

    field :key_path, :string,
      description: "Private key file for `key` auth, e.g. \"~/.ssh/id_ed25519\"."

    field :agent_socket_path, :string,
      description:
        "ssh-agent socket for `agent` auth when it is not `SSH_AUTH_SOCK`, " <>
          "e.g. \"~/.1password/agent.sock\"."
  end

  @impl true
  def execute(params, frame) do
    response =
      with {:ok, target} <- target(params),
           :ok <- check_route(target) do
        connect(target, NodeSession.current())
      else
        {:error, message} -> Response.error(Response.tool(), message)
      end

    {:reply, response, frame}
  end

  @spec id(SavedConnections.saved()) :: String.t()
  def id(%Connection{id: id}), do: "direct:#{id}"
  def id(%SshConnection{id: id}), do: "ssh:#{id}"

  defp target(%{connection_id: id}) when is_binary(id) do
    case saved(id) do
      nil -> {:error, "Unknown connection_id #{inspect(id)}, call `list_connections`"}
      saved -> {:ok, saved}
    end
  end

  defp target(%{node_name: node_name} = params) when is_binary(node_name) do
    case {Map.get(params, :ssh_user), Map.get(params, :ssh_host)} do
      {nil, nil} ->
        {:ok, direct_target(node_name, params)}

      {user, host} when is_binary(user) and is_binary(host) ->
        {:ok, ssh_target(node_name, user, host, params)}

      _ ->
        {:error, "Pass both `ssh_user` and `ssh_host` to tunnel through SSH"}
    end
  end

  defp target(_params), do: {:error, "Pass `connection_id` or `node_name`"}

  defp check_route(%SshConnection{}) do
    if ProxyEpmd.active?(),
      do: :ok,
      else: {:error, "SSH tunnels need Voyager started with its proxy epmd module"}
  end

  defp check_route(%Connection{}), do: :ok

  defp saved("direct:" <> id), do: get(id, &ConnectionQueries.get/1)
  defp saved("ssh:" <> id), do: get(id, &SshConnectionQueries.get/1)
  defp saved(_id), do: nil

  defp get(id, fun) do
    case Integer.parse(id) do
      {int_id, ""} -> fun.(int_id)
      _ -> nil
    end
  end

  defp direct_target(node_name, params) do
    ConnectionQueries.get_by_node_name(node_name) ||
      %Connection{node_name: node_name, name_type: Map.fetch!(@name_types, params.name_type)}
  end

  defp ssh_target(node_name, user, host, %{epmd_port: epmd_port} = params) do
    case SshConnectionQueries.get_by_profile(user, host, params.ssh_port, node_name) do
      %SshConnection{epmd_port: ^epmd_port} = saved ->
        saved

      _ ->
        %SshConnection{
          ssh_user: user,
          ssh_host: host,
          ssh_port: params.ssh_port,
          node_name: node_name,
          name_type: Map.fetch!(@name_types, params.name_type),
          auth_method: Map.fetch!(@auth_methods, params.auth_method),
          key_path: Map.get(params, :key_path),
          agent_socket_path: Map.get(params, :agent_socket_path),
          epmd_port: epmd_port
        }
    end
  end

  defp connect(target, session) do
    cond do
      SavedConnections.connected?(target, session) ->
        connected(target)

      session ->
        Response.error(
          Response.tool(),
          "Already connected to #{session.node_name}, call `disconnect` first to switch"
        )

      SavedConnections.ready?(target) ->
        connect_now(target)

      true ->
        hand_off(target)
    end
  end

  defp connect_now(target) do
    case SavedConnections.connect(target) do
      :ok ->
        connected(target)

      {:error, reason} ->
        message = "Could not connect to #{target.node_name}: #{ConnectError.message(reason)}"
        Response.error(Response.tool(), message)
    end
  end

  defp connected(target) do
    Response.json(Response.tool(), %{status: "connected", node: target.node_name})
  end

  defp hand_off(target) do
    path = "/?" <> URI.encode_query(form_params(target))

    payload =
      case open_window(path) do
        :ok ->
          %{
            status: "awaiting_user",
            message:
              "Voyager opened its connect form for #{target.node_name}. " <>
                "Ask the user to enter the secrets there, then call `connect` again."
          }

        :no_shell ->
          url = VoyagerWeb.Endpoint.url() <> path

          %{
            status: "awaiting_user",
            url: url,
            message:
              "Ask the user to open #{url}, enter the secrets there and connect, " <>
                "then call `connect` again."
          }
      end

    Response.json(Response.tool(), payload)
  end

  defp form_params(%Connection{id: nil} = c), do: [node_name: c.node_name, name_type: c.name_type]
  defp form_params(%Connection{id: id}), do: [connection: id]

  defp form_params(%SshConnection{id: nil} = c) do
    [
      mode: "ssh",
      node_name: c.node_name,
      name_type: c.name_type,
      ssh_user: c.ssh_user,
      ssh_host: c.ssh_host,
      ssh_port: c.ssh_port,
      epmd_port: c.epmd_port,
      auth_method: c.auth_method,
      key_path: c.key_path,
      agent_socket_path: c.agent_socket_path
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp form_params(%SshConnection{id: id}), do: [mode: "ssh", connection: id]

  defp open_window(path) do
    if Process.whereis(ElixirKit.PubSub),
      do: ElixirKit.PubSub.broadcast("messages", "open:" <> path),
      else: :no_shell
  end
end

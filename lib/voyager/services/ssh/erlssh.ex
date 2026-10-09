defmodule Voyager.Services.Ssh.Erlssh do
  @moduledoc false

  @behaviour Voyager.Services.Ssh

  alias Voyager.Services.Distribution
  alias Voyager.Services.Ssh

  require Ssh

  @ssh_timeout 5000

  @impl true
  def connect(host, port, user, auth) when Ssh.is_ssh_auth(auth) do
    opts =
      [
        user: String.to_charlist(user),
        user_interaction: false,
        silently_accept_hosts: true,
        connect_timeout: @ssh_timeout
      ] ++ auth_opts(auth)

    :ssh.connect(Distribution.host_address(host), port, opts)
  end

  @impl true
  def open_tunnel(conn, remote_host, remote_port) do
    :ssh.tcpip_tunnel_to_server(
      conn,
      ~c"127.0.0.1",
      0,
      String.to_charlist(remote_host),
      remote_port
    )
  end

  @impl true
  def close(conn), do: :ssh.close(conn)

  defp auth_opts(:agent), do: [key_cb: {:ssh_agent, []}]
  defp auth_opts({:password, pass}), do: [password: String.to_charlist(pass)]
end

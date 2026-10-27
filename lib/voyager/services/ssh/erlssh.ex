defmodule Voyager.Services.SSH.Erlssh do
  @moduledoc false

  @behaviour Voyager.Services.SSH

  alias Voyager.Services.Distribution
  alias Voyager.Services.SSH
  alias Voyager.Services.SSH.KeyFile

  require SSH

  @ssh_timeout 5000
  @alive %{interval: 15_000, count_max: 3}

  @impl true
  def connect(host, port, user, auth) when SSH.is_ssh_auth(auth) do
    opts =
      [
        user: String.to_charlist(user),
        user_interaction: false,
        silently_accept_hosts: true,
        save_accepted_host: false,
        connect_timeout: @ssh_timeout,
        alive: Application.get_env(:voyager, :ssh_alive, @alive)
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

  defp auth_opts({:key, key}), do: [key_cb: {KeyFile, key: key}]
end

defmodule Voyager.Services.SSH.Erlssh do
  @moduledoc false

  @behaviour Voyager.Services.SSH

  alias Voyager.Services.Distribution
  alias Voyager.Services.SSH
  alias Voyager.Services.SSH.KeyFile
  alias Voyager.Services.SSH.KnownHosts

  require SSH

  @ssh_timeout 5000
  @alive %{interval: 15_000, count_max: 3}

  @impl true
  def connect(host, port, user, auth, opts) when SSH.is_ssh_auth(auth) do
    ref = make_ref()
    caller = self()
    {user_key_cb, key_opts} = key_cb(auth)

    ssh_opts =
      [
        user: String.to_charlist(user),
        user_interaction: false,
        silently_accept_hosts: {:sha256, accept_host(caller, ref, opts[:host_key])},
        save_accepted_host: true,
        key_cb:
          {KnownHosts, [host: host, user_key_cb: user_key_cb, notify: {caller, ref}] ++ key_opts},
        connect_timeout: @ssh_timeout,
        alive: Application.get_env(:voyager, :ssh_alive, @alive)
      ] ++ password_opts(auth)

    case :ssh.connect(Distribution.host_address(host), port, ssh_opts) do
      {:ok, conn} ->
        {:ok, conn}

      # The connection process runs the host key callbacks before it replies, so any notice is already here.
      {:error, reason} ->
        receive do
          {^ref, host_key_error} -> {:error, host_key_error}
        after
          0 -> {:error, reason}
        end
    end
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

  defp accept_host(caller, ref, accepted) do
    fn _peer, fingerprint ->
      fingerprint = to_string(fingerprint)

      if fingerprint == accepted do
        true
      else
        send(caller, {ref, {:unknown_host_key, fingerprint}})
        false
      end
    end
  end

  defp key_cb(:agent), do: {:ssh_agent, []}
  defp key_cb({:password, _pass}), do: {:ssh_file, []}
  defp key_cb({:key, path, passphrase}), do: {KeyFile, path: path, passphrase: passphrase}

  defp password_opts({:password, pass}), do: [password: String.to_charlist(pass)]
  defp password_opts(_auth), do: []
end

defmodule Voyager.Test.SshServer do
  @moduledoc """
  Test-owned `:ssh.daemon` on a random port of `address` with an in-memory host key.

  Accepts password logins for `user/0` / `password/0`, public key logins for
  `user/0` with any of the `:authorized_keys` passed to `start!/2` (decoded
  public keys, e.g. from `:ssh_file.decode(pub, :public_key)`), and allows
  `direct-tcpip` tunnels. Each accepted login sends
  `{:ssh_server_connection, pid}` to the caller, where `pid` is the process
  serving that connection. The daemon is stopped on test exit.
  """

  @behaviour :ssh_server_key_api

  import ExUnit.Callbacks, only: [on_exit: 1]

  @user "voyager"
  @password "secret"

  def user, do: @user
  def password, do: @password

  @spec start!(:inet.ip_address(), authorized_keys: [:public_key.public_key()]) :: %{
          port: :inet.port_number(),
          daemon: :ssh.daemon_ref(),
          host_key: :public_key.public_key(),
          fingerprint: String.t()
        }
  def start!(address, opts \\ []) do
    host_key = :public_key.generate_key({:namedCurve, :ed25519})
    authorized_keys = Keyword.get(opts, :authorized_keys, [])
    caller = self()

    {:ok, daemon} =
      :ssh.daemon(address, 0,
        key_cb: {__MODULE__, host_key: host_key, authorized_keys: authorized_keys},
        user_passwords: [{String.to_charlist(@user), String.to_charlist(@password)}],
        tcpip_tunnel_in: true,
        connectfun: fn _user, _peer, _method -> send(caller, {:ssh_server_connection, self()}) end
      )

    on_exit(fn ->
      # A test may have stopped it already to drop live connections.
      try do
        :ssh.stop_daemon(daemon)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, info} = :ssh.daemon_info(daemon)
    public_host_key = :ssh_file.extract_public_key(host_key)

    %{
      port: Keyword.fetch!(info, :port),
      daemon: daemon,
      host_key: public_host_key,
      fingerprint: to_string(:ssh.hostkey_fingerprint(:sha256, public_host_key))
    }
  end

  @impl true
  def host_key(_algorithm, opts), do: {:ok, opts[:key_cb_private][:host_key]}

  @impl true
  def is_auth_key(public_key, user, opts) do
    List.to_string(user) == @user and public_key in opts[:key_cb_private][:authorized_keys]
  end
end

defmodule Voyager.Test.SshServer do
  @moduledoc """
  Test-owned `:ssh.daemon` on a random loopback port with an in-memory host key.

  Accepts password logins for `user/0` / `password/0` and allows `direct-tcpip`
  tunnels. The daemon is stopped on test exit.
  """

  @behaviour :ssh_server_key_api

  import ExUnit.Callbacks, only: [on_exit: 1]

  @user "voyager"
  @password "secret"

  def user, do: @user
  def password, do: @password

  @spec start!() :: %{port: :inet.port_number(), daemon: :ssh.daemon_ref()}
  def start! do
    host_key = :public_key.generate_key({:namedCurve, :ed25519})

    {:ok, daemon} =
      :ssh.daemon({127, 0, 0, 1}, 0,
        key_cb: {__MODULE__, host_key: host_key},
        user_passwords: [{String.to_charlist(@user), String.to_charlist(@password)}],
        tcpip_tunnel_in: true
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
    %{port: Keyword.fetch!(info, :port), daemon: daemon}
  end

  @impl true
  def host_key(_algorithm, opts), do: {:ok, opts[:key_cb_private][:host_key]}

  @impl true
  def is_auth_key(_public_key, _user, _opts), do: false
end

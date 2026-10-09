defmodule Voyager.Services.Ssh do
  @moduledoc """
  SSH transport used by `Voyager.Services.RemoteNodeConnector`.

  `connect/4` returns once authenticated, with a `t:conn/0` pid that exits when
  the SSH connection is gone. `open_tunnel/3` listens on `127.0.0.1` until
  `close/1`.
  """

  alias Voyager.Services.Ssh.Erlssh

  @type conn :: pid()
  @type auth :: :agent | {:password, String.t()}

  @callback connect(host :: String.t(), port :: :inet.port_number(), user :: String.t(), auth()) ::
              {:ok, conn()} | {:error, term()}

  @callback open_tunnel(conn(), remote_host :: String.t(), remote_port :: :inet.port_number()) ::
              {:ok, local_port :: :inet.port_number()} | {:error, term()}

  @callback close(conn()) :: :ok

  defguard is_ssh_auth(auth)
           when auth == :agent or
                  (is_tuple(auth) and tuple_size(auth) == 2 and elem(auth, 0) == :password and
                     is_binary(elem(auth, 1)))

  @spec connect(String.t(), :inet.port_number(), String.t(), auth()) ::
          {:ok, conn()} | {:error, term()}
  defdelegate connect(host, port, user, auth), to: Erlssh

  @spec open_tunnel(conn(), String.t(), :inet.port_number()) ::
          {:ok, :inet.port_number()} | {:error, term()}
  defdelegate open_tunnel(conn, remote_host, remote_port), to: Erlssh

  @spec close(conn()) :: :ok
  defdelegate close(conn), to: Erlssh
end

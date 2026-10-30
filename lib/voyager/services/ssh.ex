defmodule Voyager.Services.SSH do
  @moduledoc """
  SSH transport used by `Voyager.Services.RemoteNodeConnector`.

  `connect/4` returns once authenticated, with a `t:conn/0` pid that exits when
  the SSH connection is gone. `open_tunnel/3` listens on `127.0.0.1` until
  `close/1`.
  """

  @type conn :: pid()
  @type auth ::
          {:agent, Path.t() | nil} | {:password, String.t()} | {:key, Path.t(), String.t() | nil}

  @callback connect(host :: String.t(), port :: :inet.port_number(), user :: String.t(), auth()) ::
              {:ok, conn()} | {:error, term()}

  @callback open_tunnel(conn(), remote_host :: String.t(), remote_port :: :inet.port_number()) ::
              {:ok, local_port :: :inet.port_number()} | {:error, term()}

  @callback close(conn()) :: :ok

  defguardp is_agent_auth(auth)
            when is_tuple(auth) and tuple_size(auth) == 2 and elem(auth, 0) == :agent and
                   (is_binary(elem(auth, 1)) or is_nil(elem(auth, 1)))

  defguardp is_password_auth(auth)
            when is_tuple(auth) and tuple_size(auth) == 2 and elem(auth, 0) == :password and
                   is_binary(elem(auth, 1))

  defguardp is_key_auth(auth)
            when is_tuple(auth) and tuple_size(auth) == 3 and elem(auth, 0) == :key and
                   is_binary(elem(auth, 1)) and
                   (is_binary(elem(auth, 2)) or is_nil(elem(auth, 2)))

  defguard is_ssh_auth(auth)
           when is_agent_auth(auth) or is_password_auth(auth) or is_key_auth(auth)

  @spec connect(String.t(), :inet.port_number(), String.t(), auth()) ::
          {:ok, conn()} | {:error, term()}
  def connect(host, port, user, auth), do: impl().connect(host, port, user, auth)

  @spec open_tunnel(conn(), String.t(), :inet.port_number()) ::
          {:ok, :inet.port_number()} | {:error, term()}
  def open_tunnel(conn, remote_host, remote_port),
    do: impl().open_tunnel(conn, remote_host, remote_port)

  @spec close(conn()) :: :ok
  def close(conn), do: impl().close(conn)

  defp impl, do: Application.get_env(:voyager, :ssh, __MODULE__.Erlssh)
end

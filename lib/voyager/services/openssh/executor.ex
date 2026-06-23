defmodule Voyager.Services.OpenSSH.Executor do
  @moduledoc """
  One-shot command execution over SSH using the OpenSSH `ssh` binary.

  Used for short-lived remote commands such as `epmd -names`. Persistent
  tunnels live in `Voyager.Services.OpenSSH.Tunnel`.

  `BatchMode=yes` is forced — the binary will never prompt for a passphrase or
  password. Encrypted private keys must therefore be loaded into `ssh-agent`
  (use `:agent` auth); plain unencrypted keys work via `{:key, path}`.
  """

  alias Voyager.Services.OpenSSH.KnownHosts
  alias Voyager.Services.OpenSSH.Validate

  @type auth :: :agent | {:key, Path.t()}

  @connect_timeout_s 10

  @spec exec(String.t(), String.t(), pos_integer(), auth(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def exec(user, host, ssh_port, auth, command, opts \\ [])
      when is_binary(user) and is_binary(host) and is_integer(ssh_port) and is_binary(command) do
    with {:ok, user} <- Validate.user(user),
         {:ok, host} <- Validate.host(host) do
      prefix = opts |> Keyword.get(:epmd_prefix, []) |> Enum.join(" ")
      full_cmd = if prefix == "", do: command, else: "#{prefix} #{command}"

      args = base_args(user, host, ssh_port) ++ auth_args(auth) ++ ["--", full_cmd]

      case System.cmd(ssh!(), args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, String.trim(output)}
        {output, code} -> {:error, {:exec_failed, code, String.trim(output)}}
      end
    end
  end

  @spec ssh!() :: String.t()
  def ssh! do
    System.find_executable("ssh") || raise "ssh not found in PATH"
  end

  defp base_args(user, host, ssh_port) do
    [
      "-o",
      "StrictHostKeyChecking=yes",
      "-o",
      "UserKnownHostsFile=#{KnownHosts.path()}",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=#{@connect_timeout_s}",
      "-p",
      "#{ssh_port}",
      "#{user}@#{host}"
    ]
  end

  defp auth_args(:agent), do: []
  defp auth_args({:key, path}), do: ["-i", path, "-o", "IdentitiesOnly=yes"]
end

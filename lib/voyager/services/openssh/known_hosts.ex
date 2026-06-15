defmodule Voyager.Services.OpenSSH.KnownHosts do
  @moduledoc """
  Manages `~/.voyager/known_hosts` — the OpenSSH-format known_hosts file used by
  Voyager's outbound SSH connections.

  Kept separate from `~/.ssh/known_hosts` so Voyager can manage it
  independently of the user's system file. The path can be overridden via
  `config :voyager, :known_hosts_path, "/some/path"` (used by tests).
  """

  @spec path() :: String.t()
  def path do
    case Application.get_env(:voyager, :known_hosts_path) do
      nil -> Path.expand("~/.voyager/known_hosts")
      configured -> configured
    end
  end

  @spec ensure_file!() :: :ok
  def ensure_file! do
    file = path()
    File.mkdir_p!(Path.dirname(file))
    unless File.exists?(file), do: File.write!(file, "")
    :ok
  end

  @spec known?(String.t()) :: boolean()
  def known?(host) do
    ensure_file!()

    case System.cmd(keygen!(), ["-F", host, "-f", path()], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  @spec add(String.t(), String.t()) :: :ok
  def add(host, raw_keyscan_output) when is_binary(host) and is_binary(raw_keyscan_output) do
    ensure_file!()
    _ = System.cmd(keygen!(), ["-R", host, "-f", path()], stderr_to_stdout: true)
    File.write!(path(), String.trim_trailing(raw_keyscan_output) <> "\n", [:append])
  end

  defp keygen! do
    System.find_executable("ssh-keygen") || raise "ssh-keygen not found in PATH"
  end
end

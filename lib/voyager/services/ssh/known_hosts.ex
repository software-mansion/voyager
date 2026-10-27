defmodule Voyager.Services.SSH.KnownHosts do
  @moduledoc """
  `:ssh_client_key_api` callback that checks host keys against the system
  `~/.ssh/known_hosts` and Voyager's own `known_hosts`, and pins accepted keys
  only in Voyager's file.

  User keys are delegated to the module in `key_cb_private[:user_key_cb]`.
  On a mismatch it sends `{ref, :host_key_mismatch}` to the
  `key_cb_private[:notify]` `{pid, ref}`.
  """

  @behaviour :ssh_client_key_api

  alias Voyager.Repo
  alias Voyager.Services.LocalFiles

  @impl true
  def is_host_key(key, hosts, port, _algorithm, opts) do
    case lookup(hosts, port, key) do
      :known ->
        true

      :unknown ->
        false

      :mismatch ->
        {pid, ref} = opts[:key_cb_private][:notify]
        send(pid, {ref, :host_key_mismatch})
        {:error, :host_key_mismatch}
    end
  end

  @impl true
  def add_host_key(hosts, port, key, _opts) do
    hostnames = hosts |> names(port) |> Enum.map(&String.to_charlist/1)
    line = :ssh_file.encode([{key, [hostnames: hostnames]}], :known_hosts)
    LocalFiles.write(path(), line, [:append])
  end

  @impl true
  def user_key(algorithm, opts), do: user_key_cb(opts).user_key(algorithm, opts)

  @impl true
  def sign(blob, data, opts), do: user_key_cb(opts).sign(blob, data, opts)

  defp user_key_cb(opts), do: opts[:key_cb_private][:user_key_cb]

  defp lookup(hosts, port, key) do
    [type, blob | _] = String.split(:ssh_file.encode([{key, []}], :openssh_key))
    names = names(hosts, port)

    stored =
      for file <- [system_path(), path()],
          {:ok, contents} <- [File.read(file)],
          line <- String.split(contents, "\n"),
          [patterns, ^type, stored_blob | _] <- [String.split(line)],
          listed?(patterns, names),
          do: stored_blob

    cond do
      blob in stored -> :known
      stored == [] -> :unknown
      true -> :mismatch
    end
  end

  defp listed?(patterns, names) do
    patterns
    |> String.split(",")
    |> Enum.any?(&(&1 in names or hashed_match?(&1, names)))
  end

  defp hashed_match?("|1|" <> hashed, names) do
    with [salt, hash] <- String.split(hashed, "|"),
         {:ok, salt} <- Base.decode64(salt),
         {:ok, hash} <- Base.decode64(hash) do
      Enum.any?(names, &(:crypto.mac(:hmac, :sha, salt, &1) == hash))
    else
      _ -> false
    end
  end

  defp hashed_match?(_pattern, _names), do: false

  defp names(hosts, port) do
    hosts
    |> Enum.map(&host_name/1)
    |> Enum.uniq()
    |> Enum.map(&with_port(&1, port))
  end

  defp host_name(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp host_name(host), do: host |> to_string() |> String.downcase()

  defp with_port(host, 22), do: host
  defp with_port(host, port), do: "[#{host}]:#{port}"

  defp system_path, do: Path.join([System.get_env("HOME", ""), ".ssh", "known_hosts"])

  defp path do
    Application.get_env(:voyager, :known_hosts_path) ||
      Path.join(Path.dirname(Repo.config()[:database]), "known_hosts")
  end
end

defmodule Voyager.Services.SSH.KnownHosts do
  @moduledoc """
  `:ssh_client_key_api` callback that checks host keys against the system
  `~/.ssh/known_hosts` and Voyager's own `known_hosts`, and pins accepted keys
  only in Voyager's file.

  Hosts are looked up and pinned by `key_cb_private[:host]`, the name the user
  connected to. User keys are delegated to the module in
  `key_cb_private[:user_key_cb]`. A failed check also sends `{ref, reason}` to
  the `key_cb_private[:notify]` `{pid, ref}`.
  """

  @behaviour :ssh_client_key_api

  alias Voyager.Repo
  alias Voyager.Services.LocalFiles

  @impl true
  def is_host_key(key, _hosts, port, _algorithm, opts) do
    case lookup(name(port, opts), key) do
      :known ->
        true

      :unknown ->
        false

      {:error, reason} = error ->
        {pid, ref} = opts[:key_cb_private][:notify]
        send(pid, {ref, reason})
        error
    end
  end

  @impl true
  def add_host_key(_hosts, port, key, opts) do
    hostnames = [String.to_charlist(name(port, opts))]
    line = :ssh_file.encode([{key, [hostnames: hostnames]}], :known_hosts)
    LocalFiles.write(path(), line, [:append])
  end

  @impl true
  def user_key(algorithm, opts), do: user_key_cb(opts).user_key(algorithm, opts)

  @impl true
  def sign(blob, data, opts), do: user_key_cb(opts).sign(blob, data, opts)

  defp user_key_cb(opts), do: opts[:key_cb_private][:user_key_cb]

  defp name(port, opts), do: opts[:key_cb_private][:host] |> String.downcase() |> with_port(port)

  defp with_port(host, 22), do: host
  defp with_port(host, port), do: "[#{host}]:#{port}"

  defp lookup(name, key) do
    [type, blob | _] = String.split(:ssh_file.encode([{key, []}], :openssh_key))

    with {:ok, entries} <- entries(name, type) do
      revoked = for {file, "revoked", ^blob} <- entries, do: file
      plain = for {file, nil, stored} <- entries, do: {file, stored}

      cond do
        revoked != [] -> {:error, {:host_key_revoked, hd(revoked)}}
        Enum.any?(plain, &match?({_file, ^blob}, &1)) -> :known
        plain == [] -> :unknown
        true -> {:error, {:host_key_mismatch, plain |> hd() |> elem(0)}}
      end
    end
  end

  defp entries(name, type) do
    Enum.reduce_while([system_path(), path()], {:ok, []}, fn file, {:ok, entries} ->
      case LocalFiles.read(file) do
        {:ok, contents} -> {:cont, {:ok, entries ++ parse(file, contents, name, type)}}
        {:error, {:read_failed, {_path, :enoent}}} -> {:cont, {:ok, entries}}
        {:error, _reason} -> {:halt, {:error, {:known_hosts_unreadable, file}}}
      end
    end)
  end

  defp parse(file, contents, name, type) do
    for line <- String.split(contents, "\n"),
        {marker, [patterns, ^type, stored | _]} <- [marker(String.split(line))],
        listed?(patterns, name),
        do: {file, marker, stored}
  end

  defp marker(["@" <> marker | fields]), do: {marker, fields}
  defp marker(fields), do: {nil, fields}

  defp listed?("|1|" <> hashed, name) do
    with [salt, hash] <- String.split(hashed, "|"),
         {:ok, salt} <- Base.decode64(salt),
         {:ok, hash} <- Base.decode64(hash) do
      :crypto.mac(:hmac, :sha, salt, name) == hash
    else
      _ -> false
    end
  end

  defp listed?(patterns, name) do
    {negated, positive} =
      patterns
      |> String.downcase()
      |> String.split(",")
      |> Enum.split_with(&String.starts_with?(&1, "!"))

    Enum.any?(positive, &glob?(&1, name)) and
      not Enum.any?(negated, &glob?(String.trim_leading(&1, "!"), name))
  end

  defp glob?(pattern, name) do
    regex = pattern |> Regex.escape() |> String.replace("\\*", ".*") |> String.replace("\\?", ".")
    Regex.match?(Regex.compile!("\\A#{regex}\\z"), name)
  end

  defp system_path, do: Path.join([System.get_env("HOME", ""), ".ssh", "known_hosts"])

  defp path do
    Application.get_env(:voyager, :known_hosts_path) ||
      Path.join(Path.dirname(Repo.config()[:database]), "known_hosts")
  end
end

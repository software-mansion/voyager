defmodule Voyager.Services.OpenSSH.HostScanner do
  @moduledoc """
  Trust-on-first-use host key discovery using OpenSSH's `ssh-keyscan` and
  `ssh-keygen -lf`.

  `scan/2` returns both the raw `ssh-keyscan` output (suitable for direct
  append to `known_hosts` via `KnownHosts.add/2`) and a parsed list of
  fingerprints for display in a confirmation UI.
  """

  alias Voyager.Services.OpenSSH.KnownHosts

  @type fingerprint :: %{
          bits: pos_integer(),
          hash: String.t(),
          comment: String.t(),
          type: String.t()
        }

  @keyscan_timeout_s 10

  @spec known?(String.t()) :: boolean()
  defdelegate known?(host), to: KnownHosts

  @doc """
  Scans `host` and unconditionally adds its keys to the Voyager known_hosts
  file. Use after the user has confirmed they trust the host (e.g. via a
  TOFU dialog) — or as a one-shot "trust without review" call.

  Returns the parsed fingerprints so the caller can log or surface what was
  added.
  """
  @spec trust(String.t(), pos_integer()) :: {:ok, [fingerprint()]} | {:error, term()}
  def trust(host, port \\ 22) when is_binary(host) and is_integer(port) do
    with {:ok, raw, fingerprints} <- scan(host, port),
         :ok <- KnownHosts.add(host, raw) do
      {:ok, fingerprints}
    end
  end

  @spec scan(String.t(), pos_integer()) ::
          {:ok, String.t(), [fingerprint()]} | {:error, term()}
  def scan(host, port \\ 22) when is_binary(host) and is_integer(port) do
    tmp = Path.join(System.tmp_dir!(), "voyager_scan_#{System.unique_integer([:positive])}")

    try do
      with {:ok, raw} <- run_keyscan(host, port),
           :ok <- File.write(tmp, raw),
           {:ok, fp_output} <- run_keygen_lf(tmp) do
        {:ok, raw, parse_fingerprints(fp_output)}
      end
    after
      File.rm(tmp)
    end
  end

  @spec parse_fingerprints(String.t()) :: [fingerprint()]
  def parse_fingerprints(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp run_keyscan(host, port) do
    args = [
      "-T",
      "#{@keyscan_timeout_s}",
      "-t",
      "rsa,ecdsa,ed25519",
      "-p",
      "#{port}",
      host
    ]

    case System.cmd(keyscan!(), args, stderr_to_stdout: true) do
      {output, 0} ->
        trimmed = String.trim(output)

        if trimmed == "" do
          {:error, :no_keys_returned}
        else
          {:ok, output}
        end

      {output, code} ->
        {:error, {:keyscan_failed, code, String.trim(output)}}
    end
  end

  defp run_keygen_lf(file) do
    case System.cmd(keygen!(), ["-lf", file], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:keygen_failed, code, String.trim(output)}}
    end
  end

  defp parse_line(line) do
    case Regex.run(~r/^(\d+)\s+(SHA256:\S+)\s+(\S+)\s+\(([^)]+)\)$/, line) do
      [_, bits, hash, comment, type] ->
        %{bits: String.to_integer(bits), hash: hash, comment: comment, type: type}

      _ ->
        nil
    end
  end

  defp keyscan!, do: System.find_executable("ssh-keyscan") || raise("ssh-keyscan not in PATH")
  defp keygen!, do: System.find_executable("ssh-keygen") || raise("ssh-keygen not in PATH")
end

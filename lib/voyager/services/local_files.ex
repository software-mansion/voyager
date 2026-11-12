defmodule Voyager.Services.LocalFiles do
  @moduledoc false

  @max_bytes 1_048_576

  @type read_error :: File.posix() | :not_regular_file | :bad_permissions | :too_large

  @spec read(Path.t()) :: {:ok, binary()} | {:error, {:read_failed, {Path.t(), File.posix()}}}
  def read(path) do
    path = Path.expand(path)

    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:read_failed, {path, reason}}}
    end
  end

  @doc """
  Reads a config file, refusing group- or world-writable files as ssh does, plus
  non-regular files and anything over 1 MiB. ssh's owner check is skipped: the BEAM has no getuid.

  Permission rule: https://github.com/openssh/openssh-portable/blob/V_10_6_P2/readconf.c#L2647-L2655
  """
  @spec read_config(Path.t()) ::
          {:ok, binary()} | {:error, {:read_failed, {Path.t(), read_error()}}}
  def read_config(path), do: read_regular(path, &config_permissions/1)

  @spec read_key(Path.t()) :: {:ok, binary()} | {:error, {:read_failed, {Path.t(), read_error()}}}
  def read_key(path), do: read_regular(path, fn _stat -> :ok end)

  defp read_regular(path, check_permissions) do
    path = Path.expand(path)

    with {:ok, %File.Stat{type: :regular} = stat} <- File.stat(path),
         :ok <- check_permissions.(stat),
         {:ok, contents} <- read_at_most(path, @max_bytes) do
      {:ok, contents}
    else
      {:ok, %File.Stat{}} -> {:error, {:read_failed, {path, :not_regular_file}}}
      {:error, reason} -> {:error, {:read_failed, {path, reason}}}
    end
  end

  defp config_permissions(%File.Stat{mode: mode}) do
    if Bitwise.band(mode, 0o022) == 0, do: :ok, else: {:error, :bad_permissions}
  end

  defp read_at_most(path, max_bytes) do
    case File.open(path, [:read, :binary], &IO.binread(&1, max_bytes + 1)) do
      {:ok, :eof} -> {:ok, ""}
      {:ok, data} when is_binary(data) and byte_size(data) > max_bytes -> {:error, :too_large}
      {:ok, data} when is_binary(data) -> {:ok, data}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write(Path.t(), iodata(), [File.mode()]) ::
          :ok | {:error, {:write_failed, {Path.t(), File.posix()}}}
  def write(path, contents, modes \\ []) do
    path = Path.expand(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, contents, modes) do
      :ok
    else
      {:error, reason} -> {:error, {:write_failed, {path, reason}}}
    end
  end
end

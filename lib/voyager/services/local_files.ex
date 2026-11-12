defmodule Voyager.Services.LocalFiles do
  @moduledoc false

  @max_config_bytes 1_048_576

  @type config_read_error :: File.posix() | :not_regular_file | :bad_permissions | :too_large

  @spec read(Path.t()) :: {:ok, binary()} | {:error, {:read_failed, {Path.t(), File.posix()}}}
  def read(path) do
    path = Path.expand(path)

    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:read_failed, {path, reason}}}
    end
  end

  @doc """
  Reads a config file, refusing what ssh refuses (owned by someone other than root or the
  user, or group- or world-writable), plus non-regular files and anything over 1 MiB.

  Permission rule: https://github.com/openssh/openssh-portable/blob/V_10_6_P2/readconf.c#L2647-L2655
  """
  @spec read_config(Path.t()) ::
          {:ok, binary()} | {:error, {:read_failed, {Path.t(), config_read_error()}}}
  def read_config(path) do
    path = Path.expand(path)

    with {:ok, stat} <- File.stat(path),
         :ok <- check_config_stat(stat),
         {:ok, contents} <- read_at_most(path, @max_config_bytes) do
      {:ok, contents}
    else
      {:error, reason} -> {:error, {:read_failed, {path, reason}}}
    end
  end

  defp check_config_stat(%File.Stat{type: :regular, uid: uid, mode: mode}) do
    if uid in [0, current_uid()] and Bitwise.band(mode, 0o022) == 0,
      do: :ok,
      else: {:error, :bad_permissions}
  end

  defp check_config_stat(_stat), do: {:error, :not_regular_file}

  defp current_uid, do: File.stat!(System.user_home!()).uid

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

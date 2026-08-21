defmodule Voyager.Epmd.Daemon do
  @moduledoc """
  Manages the OS-level EPMD process.
  """
  alias Voyager.Epmd.Client
  require Logger

  @doc """
  Starts the bundled `epmd` if it isn't already running.

  OTP only auto-starts epmd when the node boots with `--name`/`--sname`.
  Voyager boots undistributed and calls `:net_kernel.start/2` later, so epmd
  must be started explicitly.
  """
  @spec start() :: :ok | {:error, term()}
  def start do
    if running?() do
      :ok
    else
      do_start()
    end
  end

  defp do_start do
    case epmd_path() do
      nil ->
        Logger.warning("Could not locate bundled epmd binary")
        {:error, :epmd_not_found}

      path ->
        try do
          case System.cmd(path, ["-daemon"], stderr_to_stdout: true) do
            {_output, 0} ->
              :ok

            {output, status} ->
              Logger.warning("epmd -daemon exited #{status}: #{output}")
              {:error, {:exit_status, status}}
          end
        rescue
          e ->
            Logger.warning("Failed to execute epmd at #{path}: #{inspect(e)}")
            {:error, {:exception, e}}
        end
    end
  end

  @doc """
  Checks if the local EPMD is reachable via TCP.
  """
  @spec running?() :: boolean()
  def running? do
    case Client.get_names(~c"127.0.0.1", 4369, 500) do
      {:ok, _text} -> true
      {:error, _reason} -> false
    end
  end

  defp epmd_path do
    root_dir = :code.root_dir() |> IO.chardata_to_string()
    candidate = Path.join([root_dir, "bin", "epmd"])

    cond do
      File.exists?(candidate) ->
        candidate

      erts_epmd = find_erts_epmd(root_dir) ->
        erts_epmd

      true ->
        System.find_executable("epmd")
    end
  end

  defp find_erts_epmd(root_dir) do
    root_dir
    |> Path.join("erts-*")
    |> Path.wildcard()
    |> Enum.sort(:desc)
    |> Enum.map(&Path.join([&1, "bin", "epmd"]))
    |> Enum.find(&File.exists?/1)
  end
end

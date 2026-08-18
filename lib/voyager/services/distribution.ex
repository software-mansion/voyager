defmodule Voyager.Services.Distribution do
  @moduledoc """
  Manages the local node's Erlang distribution lifecycle and parses remote node
  names. Shared by `Voyager.Services.NodeConnector` and
  `Voyager.Services.RemoteNodeConnector`.

  The local distribution name is `voyager<suffix>`, where `<suffix>` comes from
  the `:distribution_suffix` setting. The host part is pinned to `127.0.0.1`
  for `:longnames` and `localhost` for `:shortnames`.
  """

  alias Voyager.Settings

  require Logger

  @doc """
  Ensures the local node is alive and distributed under `name_type`
  (`:longnames` or `:shortnames`), starting or restarting distribution as needed.

  Distribution is restarted when the running node's name type or base name no
  longer matches the requested type / current `:distribution_suffix` setting.
  """
  @spec ensure_distributed(atom()) :: :ok | {:error, term()}
  def ensure_distributed(name_type) when name_type in [:longnames, :shortnames] do
    cond do
      not Node.alive?() ->
        start_distribution(name_type)

      matches_name_type?(name_type) and distribution_name_matches?() ->
        :ok

      true ->
        case :net_kernel.stop() do
          :ok -> start_distribution(name_type)
          {:error, reason} -> {:error, {:net_kernel_stop, reason}}
        end
    end
  end

  def ensure_distributed(_name_type) do
    {:error, :invalid_name_type}
  end

  @doc """
  Splits a `name@host` node name into its name and host parts.
  """
  @spec split_node_name(String.t()) ::
          {:ok, node_name :: String.t(), host :: String.t()}
          | {:error, {:invalid_node_format, String.t()}}
  def split_node_name(full_node_name) when is_binary(full_node_name) do
    case String.split(full_node_name, "@", parts: 2) do
      [name, host] -> {:ok, name, host}
      _ -> {:error, {:invalid_node_format, full_node_name}}
    end
  end

  defp distribution_name do
    suffix = Settings.get(:distribution_suffix, "")
    "voyager#{suffix}"
  end

  defp matches_name_type?(:longnames), do: :net_kernel.longnames() == true
  defp matches_name_type?(:shortnames), do: :net_kernel.longnames() == false

  defp local_node_name(:longnames), do: String.to_atom("#{distribution_name()}@127.0.0.1")
  defp local_node_name(:shortnames), do: String.to_atom("#{distribution_name()}@localhost")

  defp distribution_name_matches? do
    {:ok, name, _host} =
      Node.self()
      |> Atom.to_string()
      |> split_node_name()

    name == distribution_name()
  end

  defp start_distribution(name_type, retry_with_epmd? \\ true) do
    node_name = local_node_name(name_type)

    case :net_kernel.start(node_name, %{name_domain: name_type, hidden: true}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, pid}} ->
        Logger.warning(
          "net_kernel.start/2 returned {:already_started, #{inspect(pid)}} " <>
            "for #{inspect(node_name)} name_type=#{inspect(name_type)}"
        )

        :ok

      {:error, reason} when retry_with_epmd? ->
        Logger.warning(
          "net_kernel.start/2 failed with #{inspect(reason)}, " <>
            "attempting to start epmd and retry"
        )

        start_epmd()
        start_distribution(name_type, false)

      {:error, reason} ->
        {:error, {:net_kernel, reason}}
    end
  end

  @doc """
  Starts the bundled `epmd` if it isn't already running.

  OTP only auto-starts epmd when the node boots with `--name`/`--sname`.
  Voyager boots undistributed and calls `:net_kernel.start/2` later, so epmd
  must be started explicitly. `epmd -daemon` is idempotent: if one is already
  running on the port it detects that and exits without error.
  """
  @spec start_epmd() :: :ok
  def start_epmd do
    case epmd_path() do
      nil ->
        Logger.warning("Could not locate bundled epmd binary")

      path ->
        case System.cmd(path, ["-daemon"], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> Logger.warning("epmd -daemon exited #{status}: #{output}")
        end
    end

    :ok
  end

  defp epmd_path do
    candidate = Path.join([:code.root_dir(), "bin", "epmd"])

    if File.exists?(candidate) do
      candidate
    else
      :code.root_dir()
      |> Path.join("erts-*")
      |> Path.wildcard()
      |> List.first()
      |> case do
        nil -> nil
        erts_dir -> Path.join([erts_dir, "bin", "epmd"])
      end
    end
  end
end

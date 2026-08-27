defmodule Voyager.Services.Distribution do
  @moduledoc """
  Manages the local node's Erlang distribution lifecycle and parses remote node
  names. Shared by `Voyager.Services.NodeConnector` and
  `Voyager.Services.RemoteNodeConnector`.

  The local distribution name is `voyager<suffix>`, where `<suffix>` comes from
  the `:distribution_suffix` setting. The host part is pinned to `127.0.0.1`
  for `:longnames` and `localhost` for `:shortnames`.
  """

  alias Voyager.Epmd.Daemon
  alias Voyager.Services.Distribution.EpmdRecovery
  alias Voyager.Settings

  require Logger

  @doc """
  Ensures the local node is alive and distributed under `name_type`
  (`:longnames` or `:shortnames`), starting or restarting distribution as needed.
  """
  @spec ensure_distributed(atom()) :: :ok | {:error, term()}
  def ensure_distributed(name_type) when name_type in [:longnames, :shortnames] do
    cond do
      not Node.alive?() ->
        start_distribution(name_type)

      matches_name_type?(name_type) and distribution_name_matches?() ->
        ensure_epmd_alive(name_type)

      true ->
        restart_distribution(name_type)
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
      [name, host] ->
        {:ok, name, host}

      _ ->
        {:error, {:invalid_node_format, full_node_name}}
    end
  end

  defp distribution_name do
    suffix = Settings.get(:distribution_suffix, "")
    "voyager#{suffix}"
  end

  defp matches_name_type?(:longnames),
    do: :net_kernel.longnames() == true

  defp matches_name_type?(:shortnames),
    do: :net_kernel.longnames() == false

  defp local_node_name(:longnames),
    do: String.to_atom("#{distribution_name()}@127.0.0.1")

  defp local_node_name(:shortnames),
    do: String.to_atom("#{distribution_name()}@localhost")

  defp distribution_name_matches? do
    {:ok, name, _host} =
      Node.self()
      |> Atom.to_string()
      |> split_node_name()

    name == distribution_name()
  end

  defp ensure_epmd_alive(name_type) do
    initially_running? = Daemon.running?()

    if initially_running? do
      :ok
    else
      Logger.warning("Node is alive but local EPMD is dead. Attempting to restart EPMD...")

      start_result = Daemon.start()
      running_after_start? = start_result == :ok and Daemon.running?()

      case EpmdRecovery.action(initially_running?, start_result, running_after_start?) do
        :keep_distribution ->
          :ok

        :restart_distribution ->
          Logger.warning("Could not recover EPMD without restarting distribution.")
          restart_distribution(name_type)
      end
    end
  end

  defp restart_distribution(name_type) do
    case :net_kernel.stop() do
      :ok ->
        start_distribution(name_type)

      {:error, reason} ->
        {:error, {:net_kernel_stop, reason}}
    end
  end

  defp start_distribution(name_type, retry_with_epmd? \\ true) do
    node_name = local_node_name(name_type)

    case :net_kernel.start(node_name, %{
           name_domain: name_type,
           hidden: true
         }) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} when retry_with_epmd? ->
        handle_net_kernel_error(name_type, reason)

      {:error, reason} ->
        {:error, {:net_kernel, reason}}
    end
  end

  defp handle_net_kernel_error(name_type, reason) do
    if Daemon.running?() do
      {:error, {:net_kernel, reason}}
    else
      Logger.warning(
        "net_kernel.start/2 failed and EPMD appears down. " <>
          "Starting EPMD and retrying..."
      )

      case Daemon.ensure_running() do
        :ok ->
          start_distribution(name_type, false)

        {:error, epmd_error} ->
          {:error, {:epmd_start_failed, reason, epmd_error}}
      end
    end
  end
end

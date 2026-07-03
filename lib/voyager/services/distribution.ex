defmodule Voyager.Services.Distribution do
  @moduledoc """
  Manages the local node's Erlang distribution lifecycle and parses remote node
  names. Shared by `Voyager.Services.NodeConnector` and
  `Voyager.Services.RemoteNodeConnector`.
  """

  require Logger

  @voyager_node_name Application.compile_env(:voyager, :voyager_node_name, :voyager@localhost)

  # A longname host must contain a dot; a shortname host must not. The configured
  # name supplies only the base part — the host is chosen to match name_type so
  # `:net_kernel.start/2` does not reject the name.
  @longname_host "127.0.0.1"
  @shortname_host "localhost"

  @doc """
  Ensures the local node is alive and distributed under `name_type`
  (`:longnames` or `:shortnames`), starting or restarting distribution as needed.
  """
  @spec ensure_distributed(atom()) :: :ok | {:error, term()}
  def ensure_distributed(name_type) when name_type in [:longnames, :shortnames] do
    cond do
      not Node.alive?() ->
        start_distribution(name_type)

      matches_name_type?(name_type) ->
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

  defp matches_name_type?(:longnames), do: :net_kernel.longnames() == true
  defp matches_name_type?(:shortnames), do: :net_kernel.longnames() == false

  defp start_distribution(name_type) do
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

      {:error, reason} ->
        {:error, {:net_kernel, reason}}
    end
  end

  # Rebuilds the configured node name with a host that matches name_type so a
  # `:longnames` VM never starts under a shortname host (or vice versa).
  defp local_node_name(name_type) do
    base =
      @voyager_node_name
      |> Atom.to_string()
      |> String.split("@", parts: 2)
      |> hd()

    host = if name_type == :longnames, do: @longname_host, else: @shortname_host
    :"#{base}@#{host}"
  end
end

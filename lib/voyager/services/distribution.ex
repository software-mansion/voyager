defmodule Voyager.Services.Distribution do
  @moduledoc """
  Manages the local node's Erlang distribution lifecycle and parses remote node
  names. Shared by `Voyager.Services.NodeConnector` and
  `Voyager.Services.RemoteNodeConnector`.

  The local distribution name is `voyager<suffix>`, where `<suffix>` comes from
  the `:distribution_suffix` setting. Only the base name is passed to
  `:net_kernel.start/2`; the host part is derived from `name_domain`, so the
  same base name is valid for both `:longnames` and `:shortnames`.
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

  @doc """
  Returns the local distribution base name (`:"voyager<suffix>"`) built from the
  `:distribution_suffix` setting.
  """
  @spec distribution_name() :: atom()
  def distribution_name do
    suffix = Settings.get(:distribution_suffix, "")
    String.to_atom("voyager#{suffix}")
  end

  defp matches_name_type?(:longnames), do: :net_kernel.longnames() == true
  defp matches_name_type?(:shortnames), do: :net_kernel.longnames() == false

  defp distribution_name_matches? do
    {:ok, name, _host} =
      Node.self()
      |> Atom.to_string()
      |> split_node_name()

    name == Atom.to_string(distribution_name())
  end

  defp start_distribution(name_type) do
    node_name = distribution_name()

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
end

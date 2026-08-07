defmodule Voyager.ProxyEpmd do
  @moduledoc """
  Custom `-epmd_module` used by the local BEAM to resolve remote nodes through
  SSH tunnels set up by `Voyager.Services.RemoteNodeConnector`.

  `port_please/2,3` and `address_please/3` first look up the node in the
  `:proxy_epmd` ETS table (populated by `RemoteNodeConnector.connect/6`). If
  the node is registered, the locally-forwarded port and loopback address are
  returned so the distribution layer connects through the tunnel. Otherwise the
  call falls through to `:erl_epmd`.

  ETS schema:

      {node_name_charlist, %{port: pos_integer(), address: :inet.ip_address(), tunnel: pid()}}
  """

  alias Voyager.ProxyEpmd.TunnelRegistry

  @spec start_link() :: {:ok, pid()} | {:error, term()}
  def start_link, do: :erl_epmd.start_link()

  @spec register_node(charlist(), pos_integer()) :: {:ok, pos_integer()} | {:error, term()}
  def register_node(name, port), do: :erl_epmd.register_node(name, port)

  @spec register_node(charlist(), pos_integer(), :inet | :inet6) ::
          {:ok, pos_integer()} | {:error, term()}
  def register_node(name, port, family), do: :erl_epmd.register_node(name, port, family)

  @spec names(charlist()) :: {:ok, [{charlist(), pos_integer()}]} | {:error, term()}
  def names(host), do: :erl_epmd.names(host)

  @spec port_please(charlist(), charlist()) ::
          {:port, pos_integer(), pos_integer()} | :noport | :nonode
  def port_please(name, host) do
    case lookup(name) do
      {:ok, %{port: port}} -> {:port, port, 6}
      :error -> :erl_epmd.port_please(name, host)
    end
  end

  @spec port_please(charlist(), charlist(), timeout()) ::
          {:port, pos_integer(), pos_integer()} | :noport | :nonode
  def port_please(name, host, timeout) do
    case lookup(name) do
      {:ok, %{port: port}} -> {:port, port, 6}
      :error -> :erl_epmd.port_please(name, host, timeout)
    end
  end

  @spec address_please(charlist(), charlist(), :inet | :inet6) ::
          {:ok, :inet.ip_address()} | {:error, term()}
  def address_please(name, host, family) do
    case lookup(name) do
      {:ok, %{address: address}} ->
        dbg(address)
        {:ok, family_match(address, family)}

      :error ->
        resolve(name, host, family)
    end
  end

  @spec active?() :: boolean()
  def active? do
    :persistent_term.get(:voyager_epmd_module, nil) == __MODULE__ || false
  end

  defp resolve(name, host, :inet6) do
    case :erl_epmd.address_please(name, host, :inet6) do
      {:ok, _} = ok -> ok
      _ -> as_v4_mapped(host)
    end
  end

  defp resolve(name, host, family), do: :erl_epmd.address_please(name, host, family)

  defp as_v4_mapped(host) do
    dbg(host)

    case :inet.getaddr(host, :inet) do
      {:ok, address} -> {:ok, v4_mapped(address)}
      error -> error
    end
  end

  defp family_match({_, _, _, _} = address, :inet6), do: v4_mapped(address)
  defp family_match(address, _family), do: address

  defp v4_mapped({a, b, c, d}), do: {0, 0, 0, 0, 0, 0xFFFF, a * 256 + b, c * 256 + d}

  defp lookup(name) when is_list(name) do
    with ref when ref != :undefined <- :ets.whereis(TunnelRegistry.table_name()),
         [{_key, entry}] <- :ets.lookup(ref, name) do
      {:ok, entry}
    else
      _ -> :error
    end
  end

  defp lookup(_), do: :error
end

defmodule Voyager.ProxyEpmd do
  @moduledoc """
  Custom `-epmd_module` used by the local BEAM to resolve remote nodes through
  SSH tunnels set up by `Voyager.Services.RemoteNodeConnector`.

  `port_please/2,3` and `address_please/3` first look up the node in the
  `:proxy_epmd` ETS table (populated by `RemoteNodeConnector.connect/5`). If
  the node is registered, the locally-forwarded port and loopback address are
  returned so the distribution layer connects through the tunnel. Otherwise the
  call falls through to `:erl_epmd`.

  ETS schema:

      {node_name_charlist, %{port: pos_integer(), address: :inet.ip_address(), tunnel: pid()}}

  ## Setup

  The recommended way is via `mise.toml` — `ELIXIR_ERL_OPTIONS` is injected
  automatically and plain `iex -S mix phx.server` works:

      # mise.toml (already in the project root)
      [env]
      ELIXIR_ERL_OPTIONS = "-epmd_module Elixir.Voyager.ProxyEpmd -pa {{config_root}}/_build/dev/lib/voyager/ebin"

  Without mise, compile first and pass the flags manually:

      mix compile
      iex --erl "-epmd_module Elixir.Voyager.ProxyEpmd -pa _build/dev/lib/voyager/ebin" -S mix phx.server

  Or use `./dev/server.sh` which does the same thing.
  """

  @table :proxy_epmd

  def start_link, do: :erl_epmd.start_link()
  def register_node(name, port), do: :erl_epmd.register_node(name, port)
  def register_node(name, port, family), do: :erl_epmd.register_node(name, port, family)
  def names(host), do: :erl_epmd.names(host)

  def port_please(name, host) do
    case lookup(name) do
      {:ok, %{port: port}} -> {:port, port, 6}
      :error -> :erl_epmd.port_please(name, host)
    end
  end

  def port_please(name, host, timeout) do
    case lookup(name) do
      {:ok, %{port: port}} -> {:port, port, 6}
      :error -> :erl_epmd.port_please(name, host, timeout)
    end
  end

  def address_please(name, host, family) do
    case lookup(name) do
      {:ok, %{address: address}} -> {:ok, address}
      :error -> :erl_epmd.address_please(name, host, family)
    end
  end

  defp lookup(name) when is_list(name) do
    with ref when ref != :undefined <- :ets.whereis(@table),
         [{_key, entry}] <- :ets.lookup(ref, name) do
      {:ok, entry}
    else
      _ -> :error
    end
  end

  defp lookup(_), do: :error
end

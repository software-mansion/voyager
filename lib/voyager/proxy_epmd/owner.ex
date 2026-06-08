defmodule Voyager.ProxyEpmd.Owner do
  @moduledoc """
  Owns the `:proxy_epmd` ETS table that maps remote node names to local
  forwarded ports. The table outlives any individual SSH tunnel caller.
  """

  use GenServer

  @table :proxy_epmd

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end
end

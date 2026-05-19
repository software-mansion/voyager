defmodule Voyager.Test.FixtureApp.Worker do
  use GenServer

  def start_link(n) do
    GenServer.start_link(__MODULE__, %{n: n})
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end
end

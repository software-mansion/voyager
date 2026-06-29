defmodule Voyager.Test.FixtureApp.Worker do
  @moduledoc false
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

  # Test helpers to set up runtime relationships from inside the worker process
  # (so the link/monitor is owned by the worker, mirroring real apps).
  def handle_call({:link, pid}, _from, state) do
    Process.link(pid)
    {:reply, :ok, state}
  end

  def handle_call({:monitor, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, ref, state}
  end

  def handle_call({:open_port, name, settings}, _from, state) do
    port = Port.open(name, settings)
    {:reply, port, state}
  end
end

defmodule Voyager.Services.Tracer.Supervisor do
  @moduledoc false

  use Supervisor

  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Writer

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_opts), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  # A restarted Writer would drop the casts in flight and leave a gap in the saved log, so the Tracer restarts with it.
  @impl true
  def init(nil), do: Supervisor.init([Writer, Tracer], strategy: :rest_for_one)
end

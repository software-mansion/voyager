Code.require_file("ets_demo.exs", __DIR__)
Code.require_file("relations_demo.exs", __DIR__)

defmodule VoyagerDemo.Application do
  use Application

  @impl true
  def start(_type, _args) do
    tables = %{id: EtsDemo, start: {Agent, :start_link, [&EtsDemo.seed/0, [name: EtsDemo]]}}
    Supervisor.start_link([tables], strategy: :one_for_one, name: VoyagerDemo.Supervisor)
  end
end

defmodule VoyagerDemo do
  def start do
    spec =
      {:application, :voyager_demo,
       [
         description: ~c"Voyager demo node",
         vsn: ~c"0.1.0",
         modules: [EtsDemo, VoyagerDemo.Application],
         registered: [EtsDemo, VoyagerDemo.Supervisor],
         applications: [:kernel, :stdlib, :elixir],
         mod: {VoyagerDemo.Application, []}
       ]}

    :ok = :application.load(spec)
    {:ok, _started} = :application.ensure_all_started(:voyager_demo)
    {:ok, _started} = RelationsDemo.start()
    :ok
  end
end

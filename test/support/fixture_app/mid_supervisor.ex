defmodule Voyager.Test.FixtureApp.MidSupervisor do
  use Supervisor

  def start_link({name, worker_ids}) do
    Supervisor.start_link(__MODULE__, worker_ids, name: name)
  end

  @impl true
  def init(worker_ids) do
    children =
      Enum.map(worker_ids, fn n ->
        Supervisor.child_spec({Voyager.Test.FixtureApp.Worker, n},
          id: {Voyager.Test.FixtureApp.Worker, n}
        )
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end

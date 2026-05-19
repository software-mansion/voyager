defmodule Voyager.Test.FixtureApp.RootSupervisor do
  use Supervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    children = [
      Supervisor.child_spec(
        {Voyager.Test.FixtureApp.MidSupervisor, {Voyager.Test.FixtureApp.MidSupA, [1, 2]}},
        id: Voyager.Test.FixtureApp.MidSupA
      ),
      Supervisor.child_spec(
        {Voyager.Test.FixtureApp.MidSupervisor, {Voyager.Test.FixtureApp.MidSupB, [3, 4]}},
        id: Voyager.Test.FixtureApp.MidSupB
      )
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

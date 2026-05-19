defmodule Voyager.Test.FixtureApp do
  @moduledoc """
  Minimal OTP application for test fixtures.

  This application provides a deterministic 3-level supervision tree:

      RootSupervisor
      ├── MidSupA
      │   ├── Worker(1)
      │   └── Worker(2)
      └── MidSupB
          ├── Worker(3)
          └── Worker(4)
  """
  use Application

  @impl true
  def start(_type, _args) do
    Voyager.Test.FixtureApp.RootSupervisor.start_link([])
  end
end

defmodule Voyager.Test.RemoteFixture do
  @moduledoc """
  Helper for starting an application with a deterministic
  supervision tree for testing `:erpc`-driven inspectors.

  Usage in tests:

      setup do
        fixture_app = RemoteFixture.start_fixture_app!()
        on_exit(fn -> Application.stop(fixture_app) end)

        %{app: fixture_app, node: Node.self()}
      end
  """

  def start_fixture_app! do
    app_spec =
      {:application, :voyager_fixture,
       [
         {:description, ~c"Voyager test fixture app"},
         {:vsn, ~c"0.1.0"},
         {:modules,
          [
            Voyager.Test.FixtureApp,
            Voyager.Test.FixtureApp.RootSupervisor,
            Voyager.Test.FixtureApp.MidSupervisor,
            Voyager.Test.FixtureApp.Worker
          ]},
         {:registered, []},
         {:applications, [:kernel, :stdlib]},
         {:mod, {Voyager.Test.FixtureApp, []}}
       ]}

    :application.load(app_spec)
    :application.ensure_all_started(:voyager_fixture)

    # Sync: confirm boot completed without sleep
    :sys.get_state(Voyager.Test.FixtureApp.RootSupervisor)

    :voyager_fixture
  end
end

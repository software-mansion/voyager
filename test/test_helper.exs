ExUnit.start(exclude: [:integration])
Ecto.Adapters.SQL.Sandbox.mode(Voyager.Repo, :manual)

Mox.defmock(Voyager.ErpcMock, for: Voyager.Erpc)
Application.put_env(:voyager, :erpc, Voyager.ErpcMock)

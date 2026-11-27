# SSH tests need `-proto_dist dual_tcp -epmd_module Elixir.Voyager.ProxyEpmd` at boot, or Node.connect skips the tunnel.
ExUnit.start(exclude: if(Voyager.ProxyEpmd.active?(), do: [], else: [:ssh]))
# Settings a run wrote outside the sandbox would otherwise leak into every test.
Voyager.Repo.delete_all(Voyager.Schemas.Setting)
Ecto.Adapters.SQL.Sandbox.mode(Voyager.Repo, :manual)
# Without cached settings, the first term formatted would query the database outside a sandbox.
:persistent_term.put({Voyager.Services.TermSyntax, :setting}, :auto)
:persistent_term.put({Voyager.Pid, :format}, :distribution)

Mox.defmock(Voyager.ErpcMock, for: Voyager.Erpc)
Application.put_env(:voyager, :erpc, Voyager.ErpcMock)

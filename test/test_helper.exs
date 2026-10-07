# SSH tests need `-proto_dist dual_tcp -epmd_module Elixir.Voyager.ProxyEpmd` at boot, or Node.connect skips the tunnel.
ExUnit.start(exclude: if(Voyager.ProxyEpmd.active?(), do: [], else: [:ssh]))
Ecto.Adapters.SQL.Sandbox.mode(Voyager.Repo, :manual)

Mox.defmock(Voyager.ErpcMock, for: Voyager.Erpc)
Application.put_env(:voyager, :erpc, Voyager.ErpcMock)

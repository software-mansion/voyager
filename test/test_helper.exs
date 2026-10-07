# SSH tests need the VM booted with `-proto_dist dual_tcp -epmd_module Elixir.Voyager.ProxyEpmd`, otherwise Node.connect bypasses the tunnel.
ExUnit.start(exclude: if(Voyager.ProxyEpmd.active?(), do: [], else: [:ssh]))
Ecto.Adapters.SQL.Sandbox.mode(Voyager.Repo, :manual)

Mox.defmock(Voyager.ErpcMock, for: Voyager.Erpc)
Application.put_env(:voyager, :erpc, Voyager.ErpcMock)

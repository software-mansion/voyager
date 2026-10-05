defmodule Voyager.Services.TracerIntegrationTest do
  # async: false because it starts distribution for the whole VM and swaps the global erpc impl.
  use ExUnit.Case, async: false

  alias Voyager.Services.Tracer

  @moduletag :integration

  @erpc_spec %{module: "erpc", function: "execute_call", arity: 4, capture: :args, local: false}

  setup do
    unless Node.alive?() do
      {_output, 0} = System.cmd("epmd", ["-daemon"])

      {:ok, _pid} =
        :net_kernel.start(:"voyager_test_#{System.unique_integer([:positive])}@127.0.0.1", %{
          name_domain: :longnames
        })

      on_exit(fn -> :net_kernel.stop() end)
    end

    {:ok, peer, node} =
      :peer.start(%{
        name: :"voyager_peer_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true
      })

    on_exit(fn -> :peer.stop(peer) end)

    erpc = Application.get_env(:voyager, :erpc)
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
    on_exit(fn -> Application.put_env(:voyager, :erpc, erpc) end)

    :ok = Voyager.Agent.install(node)
    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.topic())

    %{node: node}
  end

  test "streams remote calls, runs one trace at a time and stops on request", %{node: node} do
    assert {:ok, %{id: id}} = Tracer.start(node, @erpc_spec)
    assert {:error, :busy} = Tracer.start(node, @erpc_spec)

    for _ <- 1..3, do: :erpc.call(node, :erlang, :node, [])

    assert_receive {:trace_events, %{id: ^id},
                    [%{mfa: {:erpc, :execute_call, 4}, args: [_ref, :erlang, :node, []]} | _]},
                   2_000

    :ok = Tracer.stop()

    assert_receive {:trace_status, %{id: ^id, status: :stopped, reason: :stopped}}, 2_000
    assert {%{status: :stopped}, [_ | _]} = Tracer.current()
  end

  test "reports a trace stopped by the remote rate limit", %{node: node} do
    spec = %{@erpc_spec | capture: :arity}
    assert {:ok, %{id: id}} = Tracer.start(node, spec)

    for _ <- 1..(Tracer.limits().max_rate + 50), do: :erpc.call(node, :erlang, :node, [])

    assert_receive {:trace_status, %{id: ^id, status: :stopped, reason: :rate_limit}}, 5_000
  end
end

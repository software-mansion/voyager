defmodule VoyagerWeb.TracingLiveTest do
  # async: false because the tracer is one global process and Mox runs in global mode.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Voyager.Fakes
  alias Voyager.Services.Tracer

  @path "/node/demo@localhost/tracing"

  setup :set_mox_global

  setup do
    Fakes.connect_node!(Fakes.node_session())

    tracer = spawn(&fake_tracer/0)

    on_exit(fn ->
      ref = Process.monitor(tracer)
      Process.exit(tracer, :kill)
      assert_receive {:DOWN, ^ref, :process, ^tracer, _reason}
      _ = :sys.get_state(Tracer)
    end)

    %{tracer: tracer}
  end

  test "starts an example and lists the events the tracer pushes", %{conn: conn, tracer: tracer} do
    expect(Voyager.ErpcMock, :call, fn :demo@localhost, _agent, :trace_start, [_, spec, _], _ ->
      assert %{module: "gen", function: "call", arity: 4, capture: :args} = spec
      {:ok, tracer}
    end)

    {:ok, view, _html} = live(conn, @path)
    view |> element("#trace-example-gen-call") |> render_click()

    assert has_element?(view, "#trace-stop")
    assert has_element?(view, "#trace-events-empty")

    push_events(tracer, [
      %{
        pid: self(),
        process: :demo_server,
        mfa: {:gen, :call, 4},
        at: 1_700_000_000_000_000,
        args: [:demo_server, :"$gen_call", :ping, 5_000],
        truncated: false
      }
    ])

    assert has_element?(view, "#trace-events tr#events-0", ":gen.call(:demo_server")
    assert has_element?(view, "#trace-example-gen-call[disabled]")
  end

  test "stop shows why the trace ended", %{conn: conn, tracer: tracer} do
    stub(Voyager.ErpcMock, :call, fn _node, _agent, :trace_start, _args, _timeout ->
      {:ok, tracer}
    end)

    {:ok, view, _html} = live(conn, @path)
    view |> element("#trace-example-ets-insert") |> render_click()
    view |> element("#trace-stop") |> render_click()
    _ = :sys.get_state(Tracer)

    assert has_element?(view, "#trace-status .badge", "Stopped")
    refute has_element?(view, "#trace-stop")
  end

  test "shows the node's refusal for a custom function", %{conn: conn} do
    expect(Voyager.ErpcMock, :call, fn _node, _agent, :trace_start, [_, spec, _], _ ->
      assert %{module: "erlang", function: "send", arity: 2, local: true} = spec
      {:error, {:refused, :erlang}}
    end)

    {:ok, view, _html} = live(conn, @path)

    view
    |> form("#trace-form", trace: %{mfa: ":erlang.send/2", capture: "arity", local: "true"})
    |> render_submit()

    assert has_element?(view, "#flash-error", "refused")
    refute has_element?(view, "#trace-stop")
  end

  test "rejects text that is not Module.function/arity without calling the node", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    view |> form("#trace-form", trace: %{mfa: "not a function"}) |> render_submit()

    assert has_element?(view, "#flash-error", "Module.function/arity")
  end

  defp push_events(tracer, events) do
    send(Process.whereis(Tracer), {:voyager_trace_events, tracer, events, 0})
    _ = :sys.get_state(Tracer)
  end

  defp fake_tracer do
    receive do
      :voyager_trace_stop ->
        send(Tracer, {:voyager_trace_done, self(), :stopped, %{events: 0, dropped: 0}})
        fake_tracer()
    end
  end
end

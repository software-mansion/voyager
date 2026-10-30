defmodule VoyagerWeb.Hooks.TracingStatusHookTest do
  # async: false because these tests replace the state of the app's Tracer and NodeSession.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Voyager.Fakes, only: [stub_erpc: 1]

  alias Voyager.Fakes
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config
  alias Voyager.Services.Tracer.Session

  setup :set_mox_global

  setup do
    previous_state = :sys.get_state(Tracer)
    :sys.replace_state(Tracer, fn _ -> %Tracer{} end)
    on_exit(fn -> :sys.replace_state(Tracer, fn _ -> previous_state end) end)
  end

  test "shows nothing while no session runs", %{conn: conn} do
    :sys.replace_state(Tracer, fn _ -> %Tracer{session: %{session() | status: :stopped}} end)

    {:ok, view, _html} = live(conn, ~p"/settings")

    refute has_element?(view, "#tracing-indicator")
  end

  test "shows the session running at mount with a link to it", %{conn: conn} do
    :sys.replace_state(Tracer, fn _ -> %Tracer{session: session()} end)

    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, ~s|#tracing-indicator[href="/node/demo%40localhost/tracing"]|)
    assert has_element?(view, "#tracing-indicator-mfa", "Date.leap_year?/1")
    assert has_element?(view, "#tracing-indicator-count", "1,234")
    assert has_element?(view, "#tracing-indicator-tip[phx-hook=Tooltip]")
  end

  test "follows the session through its broadcasts", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    refute has_element?(view, "#tracing-indicator")

    broadcast({:session_entries, session(), []})
    assert has_element?(view, "#tracing-indicator-count", "1,234")

    broadcast({:session_entries, %{session() | traces: 2_000}, []})
    assert has_element?(view, "#tracing-indicator-count", "2,000")

    broadcast({:session_entries, %{session() | status: :stopped}, []})
    refute has_element?(view, "#tracing-indicator")

    broadcast({:session_entries, session(), []})
    broadcast({:session_closed, 7})
    refute has_element?(view, "#tracing-indicator")
  end

  test "formats erlang modules and wildcards", %{conn: conn} do
    config = %Config{module: "lists", function: "_", arity: nil}
    :sys.replace_state(Tracer, fn _ -> %Tracer{session: %{session() | config: config}} end)

    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#tracing-indicator-mfa", ":lists._/_")
  end

  test "shows the indicator in the app topbar", %{conn: conn} do
    Fakes.connect_node!(Fakes.node_session(node_name: "demo@localhost"))
    stub_erpc(Fakes.node_data())
    :sys.replace_state(Tracer, fn _ -> %Tracer{session: session()} end)

    {:ok, view, _html} = live(conn, ~p"/node/demo@localhost")

    assert has_element?(view, "#tracing-indicator")
  end

  test "consumes a new session's broadcast on an app page", %{conn: conn} do
    Fakes.connect_node!(Fakes.node_session(node_name: "demo@localhost"))
    stub_erpc(Fakes.node_data())

    {:ok, view, _html} = live(conn, ~p"/node/demo@localhost")

    broadcast({:session_created, %{session() | status: :idle}})

    assert render(view)
    refute has_element?(view, "#tracing-indicator")
  end

  defp session do
    %Session{
      id: 7,
      origin: :ui,
      created_at: DateTime.utc_now(),
      node: :demo@localhost,
      config: %Config{module: "Elixir.Date", function: "leap_year?", arity: 1},
      status: :running,
      traces: 1_234
    }
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Voyager.PubSub, Tracer.topic(), message)
  end
end

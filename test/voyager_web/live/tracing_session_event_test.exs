defmodule VoyagerWeb.TracingSessionEventTest do
  # async: false because these tests swap the global erpc impl and drive the app's Tracer.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Voyager.Test.TracerFixture

  alias Voyager.Services.Tracer

  @event %{pid: self(), process: nil, mfa: {Date, :leap_year?, 1}}

  setup :setup_tracer

  test "opens a clicked event's call in the panel and closes it from the same row", %{conn: conn} do
    %{id: id} = start!(%{capture: :args, return_trace: true})
    call_traced!(1, 2)
    view = open(conn, id)
    path = ~p"/node/#{node_name()}/tracing/#{id}"

    view |> element("#entry-2-time") |> render_click()
    assert_patch(view, path <> "?seq=2")
    render_async(view)

    assert has_element?(view, "#event-panel-mfa", "Date.leap_year?/1")
    assert has_element?(view, "#event-panel-arg-1", "2024")
    assert has_element?(view, "#event-panel-value", "true")
    assert has_element?(view, "#event-panel-duration", ~r/\d+ µs|\d+\.\d+ ms/)
    assert has_element?(view, "#log-selection[data-selected='entry-2'][data-partner='entry-3']")

    view |> element("#entry-2-time") |> render_click()
    assert_patch(view, path)
    assert has_element?(view, "#event-panel.translate-x-full")
    refute has_element?(view, "#log-selection")
  end

  test "shows the same call from its outcome's row and moves the highlight", %{conn: conn} do
    %{id: id} = start!(%{return_trace: true})
    call_traced!(1, 2)
    view = open(conn, id)
    path = ~p"/node/#{node_name()}/tracing/#{id}"

    view |> element("#entry-2-time") |> render_click()
    render_async(view)
    view |> element("#entry-3-time") |> render_click()
    assert_patch(view, path <> "?seq=3")
    render_async(view)

    assert has_element?(view, "#event-panel-mfa", "Date.leap_year?/1")
    assert has_element?(view, "#event-panel-value", "true")
    assert has_element?(view, "#log-selection[data-selected='entry-3'][data-partner='entry-2']")
  end

  test "opens the event named in the URL and closes from the panel", %{conn: conn} do
    %{id: id} = start!(%{return_trace: true})
    call_traced!(1, 2)
    path = ~p"/node/#{node_name()}/tracing/#{id}"

    {:ok, view, _html} = live(conn, path <> "?seq=3")
    render_async(view)
    assert has_element?(view, "#event-panel-value", "true")

    view |> element("#event-panel-close") |> render_click()
    assert_patch(view, path)
    assert has_element?(view, "#event-panel.translate-x-full")
  end

  test "closes the panel with a notice when the event is not in the session", %{conn: conn} do
    %{id: id} = start!()
    path = ~p"/node/#{node_name()}/tracing/#{id}"

    {:ok, view, _html} = live(conn, path <> "?seq=0")
    render_async(view)

    assert_patch(view, path)
    assert has_element?(view, "#event-panel.translate-x-full")
    assert has_element?(view, "#flash-info")
  end

  test "drops a seq that is not a number", %{conn: conn} do
    %{id: id} = start!()
    path = ~p"/node/#{node_name()}/tracing/#{id}"

    assert {:error, {:live_redirect, %{to: ^path}}} = live(conn, path <> "?seq=abc")
  end

  test "ignores a selection without a valid seq", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    render_click(view, "select-event", %{})
    render_click(view, "select-event", %{"seq" => "-1"})

    assert has_element?(view, "#event-panel.translate-x-full")
  end

  test "shows neither arguments nor an outcome that the session does not trace", %{conn: conn} do
    %{id: id} = start!()
    call_traced!(1, 1)

    {:ok, view, _html} = live(conn, ~p"/node/#{node_name()}/tracing/#{id}?seq=2")
    render_async(view)

    assert has_element?(view, "#event-panel-mfa", "Date.leap_year?/1")
    refute has_element?(view, "#event-panel-args")
    refute has_element?(view, "#event-panel-outcome")
    refute has_element?(view, "#event-panel-no-outcome")
  end

  test "opens no details from a control row", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    assert has_element?(view, "#entry-0", "Configured")
    refute has_element?(view, "#entry-0 [phx-click]")
    refute has_element?(view, "#entry-1 [phx-click]")
  end

  test "shows an outcome that arrives while its call is open", %{conn: conn} do
    %{id: id} = start!(%{return_trace: true})
    trace!(%{type: :call, at: 10, args: [~D[2024-01-01]]})

    {:ok, view, _html} = live(conn, ~p"/node/#{node_name()}/tracing/#{id}?seq=2")
    render_async(view)
    assert has_element?(view, "#event-panel-no-outcome")
    refute has_element?(view, "#log-selection[data-partner]")

    trace!(%{type: :return, at: 25, value: true})
    render(view)
    render_async(view)

    refute has_element?(view, "#event-panel-no-outcome")
    assert has_element?(view, "#event-panel-value", "true")
    assert has_element?(view, "#event-panel-duration", "15 µs")
    assert has_element?(view, "#log-selection[data-partner='entry-3']")
  end

  test "shows an outcome that arrives while its call is still looked up", %{conn: conn} do
    %{id: id} = start!(%{return_trace: true})
    trace!(%{type: :call, at: 10, args: [~D[2024-01-01]]})
    view = open(conn, id)

    :sys.suspend(Tracer)
    view |> element("#entry-2-time") |> render_click()
    {lookup, _tag} = lookup_from()
    # Holds the first lookup's answer back until the outcome's broadcast has reached the view.
    true = :erlang.suspend_process(lookup)
    :sys.resume(Tracer)
    trace!(%{type: :return, at: 25, value: true})
    render(view)
    true = :erlang.resume_process(lookup)
    render_async(view)

    refute has_element?(view, "#event-panel-no-outcome")
    assert has_element?(view, "#event-panel-value", "true")
  end

  test "notes a call event that is not in the log", %{conn: conn} do
    %{id: id} = start!(%{return_trace: true})
    trace!(%{type: :return, at: 25, value: true})

    {:ok, view, _html} = live(conn, ~p"/node/#{node_name()}/tracing/#{id}?seq=2")
    render_async(view)

    assert has_element?(view, "#event-panel-no-call")
    assert has_element?(view, "#event-panel-value", "true")
    refute has_element?(view, "#event-panel-duration")
  end

  @tag :capture_log
  test "shows an error when the lookup crashes", %{conn: conn} do
    %{id: id} = start!()
    call_traced!(1, 1)
    view = open(conn, id)

    :sys.suspend(Tracer)
    view |> element("#entry-2-time") |> render_click()
    # Answers the lookup's request with traces that it cannot walk, so it raises.
    GenServer.reply(lookup_from(), {:ok, :not_traces})
    render_async(view)
    :sys.resume(Tracer)

    assert has_element?(view, "#event-panel-error")
  end

  test "ignores a lookup that ends after its panel closed", %{conn: conn} do
    %{id: id} = start!()
    call_traced!(1, 1)
    view = open(conn, id)

    :sys.suspend(Tracer)
    view |> element("#entry-2-time") |> render_click()
    _ = lookup_from()
    view |> element("#event-panel-close") |> render_click()
    :sys.resume(Tracer)
    render_async(view)

    assert has_element?(view, "#event-panel.translate-x-full")
    refute has_element?(view, "#event-panel-mfa")
    refute has_element?(view, "#flash-info")
  end

  # The lookup's `from`, once its request waits in the suspended Tracer's mailbox.
  defp lookup_from do
    {:messages, messages} = Process.info(Process.whereis(Tracer), :messages)

    case for {:"$gen_call", from, {:kept_traces, _id}} <- messages, do: from do
      [from] ->
        from

      [] ->
        Process.sleep(5)
        lookup_from()
    end
  end

  defp trace!(fields) do
    send(Tracer, {:voyager_trace_events, Tracer.active().tracer, [Map.merge(@event, fields)], 0})
    _ = :sys.get_state(Tracer)
  end
end

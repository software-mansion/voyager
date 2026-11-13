defmodule VoyagerWeb.TracingSessionsLiveTest do
  # async: false because these tests swap the global erpc impl and drive the app's Tracer.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Voyager.Test.TracerFixture

  alias Voyager.Actions.TraceEntries, as: TraceEntryActions
  alias Voyager.Repo
  alias Voyager.Schemas.TraceSession
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Config

  @node_name node_name()

  setup :setup_tracer

  defp insert_saved!(overrides \\ %{}) do
    config =
      Map.get(overrides, :config, %Config{
        module: "Elixir.Date",
        function: "leap_year?",
        arity: 1,
        max_events: 100
      })

    row =
      Repo.insert!(%TraceSession{
        origin: Map.get(overrides, :origin, :ui),
        status: Map.get(overrides, :status, :stopped),
        node: Map.get(overrides, :node, @node_name),
        config: config && Map.from_struct(config),
        stop_reason: Map.get(overrides, :stop_reason, :stopped),
        traces: Map.get(overrides, :traces, 42),
        dropped: Map.get(overrides, :dropped, 0),
        bytes: Map.get(overrides, :bytes, 2_000),
        started_at: ~U[2026-11-12 10:00:00.000000Z],
        stopped_at: ~U[2026-11-12 10:01:00.000000Z]
      })

    runs = Map.get(overrides, :runs, 1)

    if runs > 0 do
      events =
        for idx <- 1..runs do
          %{seq: idx - 1, kind: :started, at: idx * 1_000_000, origin: :ui}
        end

      TraceEntryActions.insert_all(row.id, events)
    end

    row
  end

  test "renders empty state with other-node count and switches to all nodes", %{conn: conn} do
    other = insert_saved!(%{node: "worker@127.0.0.1", stop_reason: :interrupted})

    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing")

    assert has_element?(view, "#session-count", "0")
    assert has_element?(view, "#node-filter-chip", @node_name)
    assert has_element?(view, "#tiles-empty", "1 saved on other nodes")
    assert has_element?(view, "#overview-empty")
    assert has_element?(view, "#storage-footer", "2 KB")

    view
    |> element("#tiles-show-all-nodes")
    |> render_click()

    assert_patch(view, ~p"/node/#{@node_name}/tracing?node=all")
    assert has_element?(view, "#node-picker-trigger", "All nodes")
    assert has_element?(view, "#session-count", "1")
    assert has_element?(view, "#history-tiles button[data-tone=error]", "worker@127.0.0.1")
    assert has_element?(view, "#session-card[data-session-id='#{other.id}']")
  end

  test "pins the active session once and excludes its saved row from history", %{conn: conn} do
    older = insert_saved!(%{runs: 2, traces: 120})
    active = create!(save: true)
    {:ok, _session} = configure()

    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing")

    assert has_element?(view, "#active-session-tile[data-selected]", "Active")
    refute has_element?(view, "#history-tiles #history-#{active.id}")
    assert has_element?(view, "#history-tiles #history-#{older.id}", "120 traces · 2 runs")
    assert has_element?(view, "#session-count", "2")

    view
    |> element("#history-tiles #history-#{older.id}")
    |> render_click()

    assert_patch(view, ~p"/node/#{@node_name}/tracing?session=#{older.id}")
    assert has_element?(view, "#session-card[data-session-id='#{older.id}']")
  end

  test "paginates history with Show older and disables create while running", %{conn: conn} do
    rows = for _ <- 1..22, do: insert_saved!()
    oldest = List.first(rows)

    create!()
    {:ok, _session} = configure()
    {:ok, _session} = Tracer.start(:ui)

    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing")

    assert has_element?(view, "#create-session[aria-disabled]")
    refute has_element?(view, "#history-tiles #history-#{oldest.id}")
    assert has_element?(view, "#show-older")

    view
    |> element("#show-older")
    |> render_click()

    assert has_element?(view, "#history-tiles #history-#{oldest.id}")
    refute has_element?(view, "#show-older")
  end
end

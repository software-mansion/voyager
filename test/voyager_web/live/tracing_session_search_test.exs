defmodule VoyagerWeb.TracingSessionSearchTest do
  # async: false because these tests swap the global erpc impl and drive the app's Tracer.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Voyager.Test.TracerFixture

  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Writer

  @config %{capture: :args, budget: 1_000}

  setup :setup_tracer

  test "searches the newest events of an unsaved session", %{conn: conn} do
    %{id: id} = start!(@config)
    trace_dates!([~D[2023-05-05], ~D[2024-01-01]], 2)
    view = open(conn, id)

    assert has_element?(view, "#log-search[placeholder='Search newest 500 events']")

    search(view, "2023")

    assert row_ids(view) == ["entry-2"]
    assert has_element?(view, "#log-footer", "1 match in the newest 500 events")
    refute has_element?(view, "#log-older")
  end

  test "searches all traces of a saved session and loads older matches", %{conn: conn} do
    %{id: id} = start!(@config, save: true)
    trace_dates!(List.duplicate(~D[2023-05-05], 150), 150)
    view = open(conn, id)

    assert has_element?(view, "#log-search[placeholder='Search all 150 traces']")

    search(view, "2023")

    assert has_element?(view, "#log-footer", "Newest 100 of 150 matches in 150 traces")
    assert has_element?(view, "#log-matches", "150 matches")

    trace_dates!(List.duplicate(~D[2023-05-05], 20), 170)

    view
    |> element("#log-older")
    |> render_click()

    render_async(view)

    assert has_element?(view, "#entry-2")
    assert has_element?(view, "#log-footer", "150 matches in 150 traces")
    refute has_element?(view, "#log-older")
  end

  test "shows the empty state when nothing matches", %{conn: conn} do
    %{id: id} = start!(@config)
    trace_dates!([~D[2024-01-01]], 1)
    view = open(conn, id)

    search(view, "nothing like this")

    assert row_ids(view) == []
    assert has_element?(view, "#log-no-matches")
    assert has_element?(view, "#log-footer", "No matches in the newest 500 events")
  end

  test "highlights the matched text, keeping its case", %{conn: conn} do
    %{id: id} = start!(@config)
    trace_dates!([~D[2023-05-05]], 1)
    view = open(conn, id)

    search(view, "d[2023")

    assert has_element?(view, "#entry-2 mark", "D[2023")
    refute has_element?(view, "#entry-2 mark", "-05")
  end

  test "returns to the live list once the search is cleared", %{conn: conn} do
    %{id: id} = start!(@config)
    trace_dates!([~D[2023-05-05]], 1)
    view = open(conn, id)

    search(view, "2023")
    refute has_element?(view, "#entry-0")
    refute has_element?(view, "#log-live")

    search(view, "  ")

    assert has_element?(view, "#entry-0", "Configured")
    assert has_element?(view, "#log-live")
    refute has_element?(view, "#entry-2 mark")
    refute has_element?(view, "#log-no-matches")
  end

  test "returns to the live list when the search fails", %{conn: conn} do
    %{id: id} = start!(@config, save: true)
    trace_dates!([~D[2023-05-05]], 1)
    view = open(conn, id)
    :ok = Tracer.stop(:ui)
    Writer.flush()
    Voyager.Repo.delete_all(Voyager.Schemas.TraceSession)

    search(view, "2023")

    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#log-footer", "Searching")
  end

  test "does not insert live entries while searching", %{conn: conn} do
    %{id: id} = start!(@config)
    trace_dates!([~D[2023-05-05]], 1)
    view = open(conn, id)

    search(view, "2023")
    trace_dates!([~D[2023-05-05]], 2)
    flush_log(view)

    assert row_ids(view) == ["entry-2"]
    refute has_element?(view, "#log-pause")
  end

  test "ignores the result of a superseded search", %{conn: conn} do
    %{id: id} = start!(@config)
    trace_dates!([~D[2023-05-05]], 1)
    view = open(conn, id)

    :ok = :sys.suspend(Tracer)

    view
    |> element("#log-search-form")
    |> render_change(%{search: %{query: "nothing"}})

    view
    |> element("#log-search-form")
    |> render_change(%{search: %{query: "2023"}})

    :ok = :sys.resume(Tracer)
    render_async(view)

    assert has_element?(view, "#entry-2")
    assert has_element?(view, "#log-footer", "1 match")
  end

  test "drops a pending search once cleared", %{conn: conn} do
    %{id: id} = start!(@config)
    view = open(conn, id)

    :ok = :sys.suspend(Tracer)

    view
    |> element("#log-search-form")
    |> render_change(%{search: %{query: "2023"}})

    view
    |> element("#log-search-form")
    |> render_change(%{search: %{query: ""}})

    :ok = :sys.resume(Tracer)
    render_async(view)

    assert has_element?(view, "#entry-0", "Configured")
    refute has_element?(view, "#flash-error")
  end

  defp search(view, query) do
    view
    |> element("#log-search-form")
    |> render_change(%{search: %{query: query}})

    render_async(view)
  end
end

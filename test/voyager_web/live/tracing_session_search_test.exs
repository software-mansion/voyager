defmodule VoyagerWeb.TracingSessionSearchTest do
  # async: false because these tests swap the global erpc impl and drive the app's Tracer.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Fakes
  alias Voyager.Services.Tracer
  alias Voyager.Services.Tracer.Writer
  alias Voyager.Test.VoyagerAgentFixture

  @node_name "nonode@nohost"

  setup do
    VoyagerAgentFixture.load!()

    prev_erpc = Application.get_env(:voyager, :erpc)
    Application.put_env(:voyager, :erpc, Voyager.Erpc.Impl)
    on_exit(fn -> Application.put_env(:voyager, :erpc, prev_erpc) end)

    previous_state = :sys.get_state(Tracer)
    :sys.replace_state(Tracer, fn _ -> %Tracer{} end)
    on_exit(fn -> :sys.replace_state(Tracer, fn _ -> previous_state end) end)

    on_exit(fn ->
      Tracer.stop(:ui)
      _ = :sys.get_state(Tracer)
      Writer.flush()
    end)

    Fakes.connect_node!(Fakes.node_session(node: Node.self(), node_name: @node_name))
    :ok
  end

  test "searches the newest events of an unsaved session", %{conn: conn} do
    %{id: id} = start!()
    call_traced!([~D[2023-05-05], ~D[2024-01-01]], 2)
    view = open(conn, id)

    assert has_element?(view, "#log-search[placeholder='Search newest 500 events']")

    search(view, "2023")

    assert row_ids(view) == ["entry-2"]
    assert has_element?(view, "#log-footer", "1 match in the newest 500 events")
    refute has_element?(view, "#log-older")
  end

  test "searches all traces of a saved session and loads older matches", %{conn: conn} do
    %{id: id} = start!(save: true)
    call_traced!(List.duplicate(~D[2023-05-05], 150), 150)
    view = open(conn, id)

    assert has_element?(view, "#log-search[placeholder='Search all 150 traces']")

    search(view, "2023")

    assert has_element?(view, "#log-footer", "Newest 100 of 150 matches in 150 traces")

    call_traced!(List.duplicate(~D[2023-05-05], 20), 170)
    view |> element("#log-older") |> render_click()
    render_async(view)

    assert has_element?(view, "#entry-2")
    assert has_element?(view, "#log-footer", "150 matches in 150 traces")
    refute has_element?(view, "#log-older")
  end

  test "shows the empty state when nothing matches", %{conn: conn} do
    %{id: id} = start!()
    call_traced!([~D[2024-01-01]], 1)
    view = open(conn, id)

    search(view, "nothing like this")

    assert row_ids(view) == []
    assert has_element?(view, "#log-no-matches")
    assert has_element?(view, "#log-footer", "No matches in the newest 500 events")
  end

  test "highlights the matched text, keeping its case", %{conn: conn} do
    %{id: id} = start!()
    call_traced!([~D[2023-05-05]], 1)
    view = open(conn, id)

    search(view, "d[2023")

    assert has_element?(view, "#entry-2 mark", "D[2023")
    refute has_element?(view, "#entry-2 mark", "-05")
  end

  test "returns to the live list once the search is cleared", %{conn: conn} do
    %{id: id} = start!()
    call_traced!([~D[2023-05-05]], 1)
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
    %{id: id} = start!(save: true)
    call_traced!([~D[2023-05-05]], 1)
    view = open(conn, id)
    :ok = Tracer.stop(:ui)
    Writer.flush()
    Voyager.Repo.delete_all(Voyager.Schemas.TraceSession)

    search(view, "2023")

    assert has_element?(view, "#flash-error")
    refute has_element?(view, "#log-footer", "Searching")
  end

  test "does not insert live entries while searching", %{conn: conn} do
    %{id: id} = start!()
    call_traced!([~D[2023-05-05]], 1)
    view = open(conn, id)

    search(view, "2023")
    call_traced!([~D[2023-05-05]], 2)
    flush_log(view)

    assert row_ids(view) == ["entry-2"]
    refute has_element?(view, "#log-pause")
  end

  test "ignores the result of a superseded search", %{conn: conn} do
    %{id: id} = start!()
    call_traced!([~D[2023-05-05]], 1)
    view = open(conn, id)

    :ok = :sys.suspend(Tracer)
    view |> element("#log-search-form") |> render_change(%{search: %{query: "nothing"}})
    view |> element("#log-search-form") |> render_change(%{search: %{query: "2023"}})
    :ok = :sys.resume(Tracer)
    render_async(view)

    assert has_element?(view, "#entry-2")
    assert has_element?(view, "#log-footer", "1 match")
  end

  test "drops a pending search once cleared", %{conn: conn} do
    %{id: id} = start!()
    view = open(conn, id)

    :ok = :sys.suspend(Tracer)
    view |> element("#log-search-form") |> render_change(%{search: %{query: "2023"}})
    view |> element("#log-search-form") |> render_change(%{search: %{query: ""}})
    :ok = :sys.resume(Tracer)
    render_async(view)

    assert has_element?(view, "#entry-0", "Configured")
    refute has_element?(view, "#flash-error")
  end

  defp search(view, query) do
    view |> element("#log-search-form") |> render_change(%{search: %{query: query}})
    render_async(view)
  end

  defp start!(opts \\ []) do
    {:ok, session} = Tracer.create(:ui, opts)

    {:ok, _session} =
      Tracer.configure(
        Node.self(),
        %{
          module: "Elixir.Date",
          function: "leap_year?",
          arity: 1,
          pids: [Voyager.Pid.format(self(), :distribution)],
          capture: :args,
          budget: 1_000,
          max_events: 1_000
        },
        :ui
      )

    {:ok, _session} = Tracer.start(:ui)
    Phoenix.PubSub.subscribe(Voyager.PubSub, Tracer.topic())
    session
  end

  defp call_traced!(dates, traces) do
    Enum.each(dates, &Date.leap_year?/1)
    assert_receive {:session_entries, %{traces: ^traces}, _entries}, 2_000
  end

  # The broadcast reaches the view before the Tracer handles its next message.
  defp flush_log(view) do
    _ = :sys.get_state(Tracer)
    send(view.pid, :flush_log)
    render(view)
  end

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#session-log-rows > tr")
    |> LazyHTML.attribute("id")
  end

  defp open(conn, id) do
    {:ok, view, _html} = live(conn, ~p"/node/#{@node_name}/tracing/#{id}")
    render_async(view)
    view
  end
end

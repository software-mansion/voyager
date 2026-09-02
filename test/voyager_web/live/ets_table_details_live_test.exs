defmodule VoyagerWeb.EtsTableDetailsLiveTest do
  # async: false because we use Mox global mode: the remote fetch runs in an
  # async task, so erpc expectations must be reachable from any process.
  use VoyagerWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Voyager.EtsFakes
  alias Voyager.Fakes
  alias Voyager.Services.Ets.TableId
  alias VoyagerWeb.Formatters

  @node_name "demo@localhost"

  setup :set_mox_global

  setup do
    Fakes.connect_node!(Fakes.node_session(node_name: @node_name))
    :ok
  end

  defp fixtures do
    [
      EtsFakes.table(name: :ac_tab, protection: :protected, size: 12, memory: 4_096),
      EtsFakes.table(
        name: MyApp.Cache,
        type: :ordered_set,
        size: 900,
        memory: 1_048_576,
        keypos: 2,
        decentralized_counters: true
      ),
      EtsFakes.table(
        name: :secrets,
        id: make_ref(),
        named_table: false,
        protection: :private,
        size: 3,
        memory: 512
      )
    ]
  end

  defp by_name(tables, name), do: Enum.find(tables, &(&1.name == name))

  defp path(string) do
    "/node/#{@node_name}/ets-tables/#{URI.encode(string, &URI.char_unreserved?/1)}"
  end

  defp stub_tables(tables), do: EtsFakes.stub_list(tables)

  defp open(conn, tables, string) do
    stub_tables(tables)
    {:ok, view, _html} = live(conn, path(string))
    render_async(view)
    view
  end

  describe "a found table" do
    test "renders every piece of metadata", %{conn: conn} do
      view = open(conn, fixtures(), "MyApp.Cache")

      assert has_element?(view, "h1", "MyApp.Cache")

      details = view |> element("#ets-table-details") |> render()

      for text <- [
            "ordered_set",
            "public",
            "Key position",
            "Compressed",
            "Decentralized counters"
          ] do
        assert details =~ text
      end

      assert details =~ "1,048,576 B"
    end

    test "is fetched once with the default timeout", %{conn: conn} do
      open(conn, fixtures(), "MyApp.Cache")

      assert_received {:fetched, 5_000}
      refute_received {:fetched, _timeout}
    end

    test "resolves a bare name and an inspect string", %{conn: conn} do
      assert conn |> open(fixtures(), "ac_tab") |> has_element?("h1", ":ac_tab")
      assert conn |> open(fixtures(), ":ac_tab") |> has_element?("h1", ":ac_tab")
    end

    test "resolves an unnamed table by its reference", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables, TableId.display(by_name(tables, :secrets).id))

      assert has_element?(view, "h1", ":secrets")
    end

    test "links back to the list and the owner to its process", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables, "MyApp.Cache")

      list = "/node/#{URI.encode_www_form(@node_name)}/ets-tables"
      owner = Formatters.format_pid(by_name(tables, MyApp.Cache).owner)

      assert has_element?(view, ~s|#back-to-ets-tables[href="#{list}"]|)
      assert view |> element("#ets-table-details") |> render() =~ URI.encode_www_form(owner)
    end

    test "a private table shows the badge and says why it cannot be read", %{conn: conn} do
      tables = fixtures()
      view = open(conn, tables, TableId.display(by_name(tables, :secrets).id))

      assert has_element?(view, "#ets-table-details-private-badge")
      assert has_element?(view, "#ets-table-details-peek[disabled]")
      assert view |> element("#ets-table-details-peek-note") |> render() =~ "owner process"
    end

    test "a readable table marks the peek as coming soon", %{conn: conn} do
      view = open(conn, fixtures(), "MyApp.Cache")

      assert view |> element("#ets-table-details-peek") |> render() =~ "Soon"
      refute has_element?(view, "#ets-table-details-private-badge")
    end
  end

  describe "refreshing" do
    test "refetches on demand", %{conn: conn} do
      view = open(conn, fixtures(), "MyApp.Cache")
      assert_received {:fetched, _timeout}

      view |> element("#ets-table-details-refresh") |> render_click()
      render_async(view)

      assert_received {:fetched, _timeout}
    end

    test "a failed refresh flashes and keeps the metadata", %{conn: conn} do
      view = open(conn, fixtures(), "MyApp.Cache")

      EtsFakes.stub_error(:timeout)
      view |> element("#ets-table-details-refresh") |> render_click()
      render_async(view)

      assert has_element?(view, "#flash-error")
      assert has_element?(view, "#ets-table-details")
      refute has_element?(view, "#ets-table-details-error")
    end
  end

  describe "errors" do
    test "reports a table the node does not have", %{conn: conn} do
      view = open(conn, fixtures(), "nope")

      assert has_element?(view, "h1", "nope")
      assert view |> element("#ets-table-details-error") |> render() =~ "nope"
      refute has_element?(view, "#ets-table-details")
    end

    test "reports an unreachable node", %{conn: conn} do
      EtsFakes.stub_error(:noconnection)
      {:ok, view, _html} = live(conn, path("MyApp.Cache"))
      render_async(view)

      assert view |> element("#ets-table-details-error") |> render() =~ "unreachable"
    end

    test "a refused fetch tells the user to retry", %{conn: conn} do
      stub_tables(fixtures())
      Fakes.drain_rate_limiter()

      {:ok, view, _html} = live(conn, path("MyApp.Cache"))
      render_async(view)

      assert view |> element("#ets-table-details-error") |> render() =~ "Too many requests"
    end
  end
end

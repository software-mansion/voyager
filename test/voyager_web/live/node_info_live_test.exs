defmodule VoyagerWeb.NodeInfoLiveTest do
  # async: false because we use Mox global mode (erpc calls happen in spawned
  # tasks, so expectations must be reachable from any process).
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias Voyager.Fakes

  @node_name "demo@localhost"
  @path "/node/demo@localhost"

  setup :set_mox_global

  setup do
    # Inject an active session so the NodeSessionHook on_mount lets us through.
    Fakes.connect_node!(Fakes.node_session(node_name: @node_name))
    :ok
  end

  describe "navbar" do
    test "shows the MCP status indicator", %{conn: conn} do
      stub_erpc(Fakes.node_data())

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#mcp-status")
    end
  end

  describe "mount with a reachable node" do
    test "shows the loading state on initial connect", %{conn: conn} do
      stub_erpc(Fakes.node_data())

      {:ok, _view, html} = live(conn, @path)

      assert html =~ "node-info-loading"
      assert html =~ "Fetching node info"
    end

    test "renders the snapshot content once the async fetch resolves", %{conn: conn} do
      stub_erpc(Fakes.node_data())

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#node-info-content")
      assert has_element?(view, "h1", @node_name)
      refute has_element?(view, "#node-info-error")
      refute has_element?(view, "#node-info-loading")
    end

    test "renders the runtime stat tiles from the mocked data", %{conn: conn} do
      stub_erpc(
        Fakes.node_data(
          uptime_ms: 123_456,
          io_input: 1_000,
          io_output: 2_000,
          reductions: 5_000_000
        )
      )

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#node-info-content", "2m")
      assert has_element?(view, "#node-info-content", "1000B")
      assert has_element?(view, "#node-info-content", "2KB")
      assert has_element?(view, "#node-info-content", "5,000,000")
    end

    test "renders the memory breakdown, including derived 'other', from the mocked data",
         %{conn: conn} do
      stub_erpc(
        Fakes.node_data(
          mem_total: 100_000_000,
          mem_processes: 40_000_000,
          mem_atom: 1_000_000,
          mem_binary: 5_000_000,
          mem_code: 20_000_000,
          mem_ets: 3_000_000
        )
      )

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#node-info-content", "95 MB")
      assert has_element?(view, "#node-info-content", "38 MB")
      assert has_element?(view, "#node-info-content", "40.0%")
      assert has_element?(view, "#node-info-content", "30 MB")
    end

    test "renders the system limits with thousands separators", %{conn: conn} do
      stub_erpc(
        Fakes.node_data(
          process_count: 240,
          process_limit: 262_144,
          atom_count: 12_345,
          atom_limit: 1_048_576
        )
      )

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#node-info-content", "240")
      assert has_element?(view, "#node-info-content", "262,144")
      assert has_element?(view, "#node-info-content", "12,345")
      assert has_element?(view, "#node-info-content", "1,048,576")
    end

    test "renders the runtime info card from the mocked data", %{conn: conn} do
      stub_erpc(
        Fakes.node_data(
          otp_release: "27",
          erts_version: "15.2",
          stdlib_version: "5.2",
          system_architecture: "aarch64-apple-darwin23",
          wordsize: 8
        )
      )

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#node-info-content", "27")
      assert has_element?(view, "#node-info-content", "15.2")
      assert has_element?(view, "#node-info-content", "5.2")
      assert has_element?(view, "#node-info-content", "aarch64-apple-darwin23")
      assert has_element?(view, "#node-info-content", "8 bytes")
    end

    test "shows stdlib as not available when the version lookup fails", %{conn: conn} do
      stub_erpc(Fakes.node_data(stdlib_version: nil))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#node-info-content", "Not available")
    end

    test "lists installed languages and omits absent ones", %{conn: conn} do
      stub_erpc(Fakes.node_data(elixir_version: "1.18.0", gleam_version: nil))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#node-info-content", "Elixir")
      assert has_element?(view, "#node-info-content", "1.18.0")
      refute has_element?(view, "#node-info-content", "Gleam")
    end

    test "renders scheduler and run-queue counts, including derived dirty IO", %{conn: conn} do
      stub_erpc(
        Fakes.node_data(
          schedulers: 8,
          schedulers_online: 8,
          dirty_io_schedulers: 10,
          run_queue_total: 3,
          run_queue_normal_and_dirty_cpu: 2
        )
      )

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#node-info-content", "8 / 8")
      assert has_element?(view, "#node-info-content", "10")
      assert has_element?(view, "#node-info-content", "1")
    end

    test "lists running applications sorted alphabetically", %{conn: conn} do
      stub_erpc(Fakes.node_data())

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#node-info-content", "kernel")
      assert has_element?(view, "#node-info-content", "9.2")
      assert has_element?(view, "#node-info-content", "ERTS CXC 138 10")
      assert has_element?(view, "#node-info-content", "stdlib")
      refute has_element?(view, "#applications-show-all-button")
    end

    test "clicking an application row navigates to its supervision tree", %{conn: conn} do
      stub_erpc(Fakes.node_data())

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      html = render(view)
      assert html =~ "/node/#{@node_name}/supervision-tree?apps=kernel"
    end

    test "an application without a supervision tree is not clickable", %{conn: conn} do
      stub_erpc(Fakes.node_data())

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      html = render(view)
      refute html =~ "supervision-tree?apps=stdlib"
    end

    test "shows a show-all button when applications exceed the page size, revealing the rest on click",
         %{conn: conn} do
      applications =
        for n <- 1..12, do: {:"app#{String.pad_leading("#{n}", 2, "0")}", "d#{n}", "1.0.#{n}"}

      stub_erpc(Fakes.node_data(applications: applications))

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#node-info-content", "app01")
      refute has_element?(view, "#node-info-content", "app11")
      assert has_element?(view, "#applications-show-all-button", "Show all")

      view |> element("#applications-show-all-button") |> render_click()

      assert has_element?(view, "#node-info-content", "app11")
      assert has_element?(view, "#node-info-content", "app12")
      refute has_element?(view, "#applications-show-all-button")
    end

    test "renders the auto-refresh form defaulting to Off", %{conn: conn} do
      stub_erpc(Fakes.node_data())

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#refresh-interval-form")
      assert has_element?(view, ~s|#refresh-interval option[value="off"][selected]|)
    end

    test "refresh button re-fetches and keeps content rendered", %{conn: conn} do
      stub_erpc(Fakes.node_data())

      {:ok, view, _html} = live(conn, @path)
      render_async(view)
      assert has_element?(view, "#node-info-content")

      view |> element("#refresh-interval-refresh-now-button") |> render_click()
      render_async(view)

      assert has_element?(view, "#node-info-content")
      refute has_element?(view, "#node-info-error")
    end

    test "changing the interval marks the chosen option as selected", %{conn: conn} do
      stub_erpc(Fakes.node_data())

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      view
      |> form("#refresh-interval-form")
      |> render_change(%{"interval" => "5000"})

      assert has_element?(view, ~s|#refresh-interval option[value="5000"][selected]|)
    end
  end

  describe "mount with an unreachable node" do
    test "renders an error alert when the fetch fails", %{conn: conn} do
      stub(Voyager.ErpcMock, :call, fn _node, _mod, _fun, _args ->
        :erlang.error({:erpc, :noconnection})
      end)

      stub(Voyager.ErpcMock, :call, fn _node, _mod, _fun, _args, _timeout ->
        :erlang.error({:erpc, :noconnection})
      end)

      {:ok, view, _html} = live(conn, @path)
      render_async(view)

      assert has_element?(view, "#node-info-error")
      assert has_element?(view, "#node-info-error", "Node is unreachable.")
      refute has_element?(view, "#node-info-content")
    end
  end

  describe "mount without a matching session" do
    test "redirects to the connect page", %{conn: conn} do
      Fakes.put_session(nil)

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, @path)
    end
  end

  defp stub_erpc(data) do
    stub(Voyager.ErpcMock, :call, fn _node, mod, fun, args ->
      Fakes.erpc_reply(mod, fun, args, data)
    end)

    stub(Voyager.ErpcMock, :call, fn _node, mod, fun, args, _timeout ->
      Fakes.erpc_reply(mod, fun, args, data)
    end)
  end
end

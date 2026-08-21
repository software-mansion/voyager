defmodule VoyagerWeb.SettingsLiveTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Fakes
  alias Voyager.Settings

  setup do
    previous_state = :sys.get_state(Voyager.NodeSession)
    Fakes.put_session(nil)

    on_exit(fn ->
      :sys.replace_state(Voyager.NodeSession, fn _ -> previous_state end)
      Application.delete_env(:voyager, :distribution_suffix)
    end)

    :ok
  end

  describe "layout" do
    test "renders no sidebar and a back link to the default return path", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      refute has_element?(view, "aside")
      assert has_element?(view, ~s|a[href="/"]|)
    end

    test "back link honors the return_to param", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings?return_to=/node/demo@localhost")

      assert has_element?(view, ~s|a[href="/node/demo@localhost"]|)
    end

    test "ignores an unsafe return_to and falls back to /", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings?return_to=https://evil.example")

      assert has_element?(view, ~s|a[href="/"]|)
    end

    test "ignores a protocol-relative return_to and falls back to /", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings?return_to=//evil.example")

      assert has_element?(view, ~s|a[href="/"]|)
    end
  end

  describe "appearance" do
    test "renders theme options", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, ~s|button[data-phx-theme="light"]|)
      assert has_element?(view, ~s|button[data-phx-theme="dark"]|)
      assert has_element?(view, ~s|button[data-phx-theme="system"]|)
    end
  end

  describe "distribution settings" do
    test "saves the distribution suffix setting", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#distribution-settings-form", %{
        "distribution_settings" => %{"distribution_suffix" => "_test"}
      })
      |> render_submit()

      assert Settings.get(:distribution_suffix, "") == "_test"
      assert render(view) =~ "Distribution suffix saved"
    end

    test "disables the form while a node is connected", %{conn: conn} do
      Fakes.connect_node!(Fakes.node_session(node_name: "demo@localhost"))

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#distribution-settings-connected")

      assert has_element?(
               view,
               ~s|#distribution_settings_distribution_suffix[disabled]|
             )

      assert has_element?(
               view,
               ~s|#distribution-settings-form button[type="submit"][disabled]|
             )
    end

    test "disables the form when locked by application config", %{conn: conn} do
      Application.put_env(:voyager, :distribution_suffix, "_locked")

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#distribution-settings-locked")

      assert has_element?(
               view,
               ~s|#distribution_settings_distribution_suffix[disabled]|
             )
    end
  end

  describe "mcp settings" do
    @describetag capture_log: true

    setup do
      Voyager.MCPCase.stop_mcp()
      port = Voyager.MCPCase.unique_port()
      {:ok, _} = Settings.put(:mcp_port, port)
      start_supervised!({Voyager.MCP, enabled: true})
      on_exit(fn -> Voyager.MCPCase.stop_mcp() end)
      %{mcp_port: port}
    end

    test "shows the running status and toggles the server off/on", %{conn: conn, mcp_port: port} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert render(view) =~ "Running at http://127.0.0.1:#{port}/mcp"

      view |> element("#mcp-toggle") |> render_click()
      assert render(view) =~ "Stopped"

      view |> element("#mcp-toggle") |> render_click()
      assert render(view) =~ "Running at http://127.0.0.1:#{port}/mcp"
    end

    test "re-renders the toggle when starting the server fails", %{conn: conn, mcp_port: port} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("#mcp-toggle") |> render_click()
      assert render(view) =~ "Stopped"

      {:ok, socket} = :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(socket) end)

      view |> element("#mcp-toggle") |> render_click()

      assert render(view) =~ "Stopped"
      refute has_element?(view, "#mcp-toggle[checked]")
      assert has_element?(view, ~s|#mcp-toggle[data-toggle-revision="1"]|)
    end

    test "updates the port", %{conn: conn, mcp_port: port} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      new_port = port + 1

      view
      |> form("#mcp-port-form", %{"mcp_port" => %{"port" => to_string(new_port)}})
      |> render_submit()

      assert Settings.get(:mcp_port) == new_port
      assert render(view) =~ "MCP port updated"
      assert render(view) =~ "Running at http://127.0.0.1:#{new_port}/mcp"
    end

    test "shows an error when the port is already in use", %{conn: conn, mcp_port: port} do
      {:ok, socket} = :gen_tcp.listen(port + 1, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(socket) end)

      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("#mcp-port-form", %{"mcp_port" => %{"port" => to_string(port + 1)}})
      |> render_submit()

      assert render(view) =~ "That port is already in use"
    end

    test "disables the port field when locked by application config", %{
      conn: conn,
      mcp_port: port
    } do
      Application.put_env(:voyager, :mcp_port, port)
      on_exit(fn -> Application.delete_env(:voyager, :mcp_port) end)

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#mcp-port-locked")
      assert has_element?(view, ~s|#mcp_port_port[disabled]|)
    end
  end

  describe "telemetry settings" do
    setup do
      on_exit(fn -> Voyager.Telemetry.set_enabled(true) end)
      :ok
    end

    test "shows telemetry as enabled by default and toggles it off/on", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, ~s|#telemetry-toggle[checked]|)

      view |> element("#telemetry-toggle") |> render_click()

      refute has_element?(view, ~s|#telemetry-toggle[checked]|)
      refute Settings.get(:telemetry_enabled, true)
      refute Voyager.Telemetry.enabled?()

      view |> element("#telemetry-toggle") |> render_click()

      assert has_element?(view, ~s|#telemetry-toggle[checked]|)
      assert Settings.get(:telemetry_enabled, true)
    end

    test "disables the toggle when locked by application config", %{conn: conn} do
      Application.put_env(:voyager, :telemetry_enabled, false)
      on_exit(fn -> Application.delete_env(:voyager, :telemetry_enabled) end)

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#telemetry-locked")
      assert has_element?(view, ~s|#telemetry-toggle[disabled]|)
    end
  end

  describe "pid format settings" do
    setup do
      on_exit(fn -> Settings.put(:pid_format, :distribution) end)
      :ok
    end

    test "selects distribution by default and switches to local", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, ~s|#pid-format-distribution[aria-pressed="true"]|)
      assert has_element?(view, ~s|#pid-format-local[aria-pressed="false"]|)
      assert has_element?(view, "#pid-format-distribution", "Distribution")
      assert has_element?(view, "#pid-format-local", "Local")

      view |> element("#pid-format-local") |> render_click()

      assert has_element?(view, ~s|#pid-format-local[aria-pressed="true"]|)
      assert has_element?(view, ~s|#pid-format-distribution[aria-pressed="false"]|)
      assert Settings.get(:pid_format, :distribution) == :local

      view |> element("#pid-format-distribution") |> render_click()

      assert has_element?(view, ~s|#pid-format-distribution[aria-pressed="true"]|)
      assert has_element?(view, ~s|#pid-format-local[aria-pressed="false"]|)
      assert Settings.get(:pid_format, :distribution) == :distribution
    end

    test "disables the buttons when locked by application config", %{conn: conn} do
      Application.put_env(:voyager, :pid_format, :local)
      on_exit(fn -> Application.delete_env(:voyager, :pid_format) end)

      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "#pid-format-locked")
      assert has_element?(view, ~s|#pid-format-distribution[disabled]|)
      assert has_element?(view, ~s|#pid-format-local[disabled]|)
      assert has_element?(view, ~s|#pid-format-local[aria-pressed="true"]|)
    end
  end
end

defmodule VoyagerWeb.ProcessInfoLiveTest do
  # async: false because use_real_erpc swaps the erpc impl for the whole VM.
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Voyager.TestUtils

  alias Voyager.Fakes
  alias Voyager.Test.VoyagerAgentFixture
  alias VoyagerWeb.Formatters

  @node_name "nonode@nohost"

  setup_all do: VoyagerAgentFixture.load!()

  setup :use_real_erpc

  setup do
    Fakes.connect_node!(Fakes.node_session(node: Node.self(), node_name: @node_name))
    :ok
  end

  describe "uninspectable process" do
    test "a malformed pid redirects to the process list with a flash", %{conn: conn} do
      {:error, {:live_redirect, %{to: to}}} =
        result = live(conn, ~p"/node/#{@node_name}/processes/not-a-pid")

      assert to == ~p"/node/#{@node_name}/processes"

      {:ok, _view, html} = follow_redirect(result, conn)
      assert html =~ "Invalid PID"
    end

    test "a dead process redirects to the process list with a flash", %{conn: conn} do
      {pid, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      path = ~p"/node/#{@node_name}/processes/#{Formatters.format_pid(pid)}"
      {:ok, view, _html} = live(conn, path)
      render_hook(view, "restore_settings", %{})

      flash = assert_redirect(view, ~p"/node/#{@node_name}/processes", 2_000)
      assert %{"error" => "The process is not alive."} = flash
    end
  end

  describe "dictionary" do
    # 40 three-unit entries against the smallest allowed budget leave exactly
    # one unit for the last one, which the remote truncates to a bare marker.
    test "drops a bare-marker entry and reports it through the truncation note", %{conn: conn} do
      pid = spawn_idle(fn -> for n <- 1..40, do: Process.put(:"key_#{n}", :value) end)

      path = ~p"/node/#{@node_name}/processes/#{Formatters.format_pid(pid)}"
      {:ok, view, _html} = live(conn, path)
      render_hook(view, "restore_settings", %{"dictionary" => %{"budget" => 100}})
      render_async(view, 2_000)

      view |> element("#process-tab-dictionary") |> render_click()
      render_async(view, 2_000)

      assert has_element?(view, "#dict-key-0")
      refute has_element?(view, "#dict-entry-33")
      assert has_element?(view, "#process-dictionary-truncated")
    end
  end
end

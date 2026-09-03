defmodule VoyagerWeb.Components.ProcessInfoComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.AsyncResult
  alias VoyagerWeb.Components.ProcessInfoComponents

  @remote_node :"demo@127.0.0.1"

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> query(selector) |> Enum.count()
  defp text(html, selector), do: html |> query(selector) |> LazyHTML.text()
  defp attr(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)

  defp remote_pid do
    # NEW_PID_EXT for <45.6> decoded as if it came from the inspected node.
    :erlang.binary_to_term(
      <<131, 88, 119, byte_size("demo@127.0.0.1"), "demo@127.0.0.1", 45::32, 6::32, 1::32>>
    )
  end

  defp chips(attrs) do
    defaults = [
      id: "chips",
      items: [],
      total: 0,
      node_name: "demo@127.0.0.1",
      remote_node: @remote_node
    ]

    render_component(&ProcessInfoComponents.identifier_chips/1, Keyword.merge(defaults, attrs))
  end

  describe "tab_button/1" do
    test "marks the active tab and emits set-tab" do
      html =
        render_component(&ProcessInfoComponents.tab_button/1,
          tab: :state,
          active: :state,
          label: "State"
        )

      assert attr(html, "#process-tab-state", "phx-click") == ["set-tab"]
      assert attr(html, "#process-tab-state", "phx-value-tab") == ["state"]
      assert count(html, "#process-tab-state.tab-active") == 1
      assert count(html, "#process-tab-state .tooltip") == 0
    end

    test "renders an inactive tab with a tooltip" do
      html =
        render_component(&ProcessInfoComponents.tab_button/1,
          tab: :relations,
          active: :overview,
          label: "Relations",
          tooltip: "Links, Monitors and Monitored by"
        )

      assert count(html, "#process-tab-relations.tab-active") == 0

      assert attr(html, "#process-tab-relations .tooltip", "data-tip") ==
               ["Links, Monitors and Monitored by"]
    end
  end

  describe "tab_panel/1" do
    defp panel(attrs) do
      defaults = [
        id: "panel-sec",
        section: :sec,
        active: true,
        timeout: 5_000,
        loading?: false,
        disabled: false,
        inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> "body" end}]
      ]

      render_component(&ProcessInfoComponents.tab_panel/1, Keyword.merge(defaults, attrs))
    end

    test "renders the body with a section-scoped timeout input and fetch button" do
      html = panel([])

      assert text(html, "#panel-sec") =~ "body"
      assert attr(html, "#panel-sec-timeout-form", "phx-change") == ["set-timeout"]
      assert attr(html, "#panel-sec-timeout-form input[type=hidden]", "value") == ["sec"]
      assert attr(html, "#panel-sec-timeout", "value") == ["5000"]
      assert attr(html, "#panel-sec-refresh", "phx-click") == ["fetch-sec"]
      assert count(html, "#panel-sec-fetched-at") == 0
    end

    test "shows the fetch time once set" do
      {:ok, dt, 0} = DateTime.from_iso8601("2026-06-02T09:08:07Z")
      html = panel(fetched_at: dt)

      assert text(html, "#panel-sec-fetched-at") =~ "fetched 09:08:07 UTC"
    end

    test "stays in the DOM but hidden while another tab is active" do
      html = panel(active: false)

      assert count(html, ".hidden #panel-sec") == 1
    end
  end

  describe "refresh_button/1" do
    test "emits its event and spins while loading" do
      html =
        render_component(&ProcessInfoComponents.refresh_button/1,
          id: "sec-refresh",
          event: "fetch-sec",
          label: "Refresh sec",
          loading?: true
        )

      assert attr(html, "#sec-refresh", "phx-click") == ["fetch-sec"]
      assert count(html, ~s(#sec-refresh [class*="animate-spin"])) == 1
      refute attr(html, "#sec-refresh", "disabled") == ["disabled"]
    end

    test "can be disabled and idle" do
      html =
        render_component(&ProcessInfoComponents.refresh_button/1,
          id: "sec-refresh",
          event: "fetch-sec",
          label: "Refresh sec",
          loading?: false,
          disabled: true
        )

      assert count(html, "#sec-refresh[disabled]") == 1
      assert count(html, ~s(#sec-refresh [class*="animate-spin"])) == 0
    end
  end

  describe "fetch_alert/1" do
    test "renders the message in an error alert by default" do
      html =
        render_component(&ProcessInfoComponents.fetch_alert/1, id: "err", message: "Boom.")

      assert text(html, "#err.alert-error") =~ "Boom."
    end

    test "renders an info alert for facts like a missing state" do
      html =
        render_component(&ProcessInfoComponents.fetch_alert/1,
          id: "note",
          kind: :info,
          message: "No state."
        )

      assert text(html, "#note.alert-info") =~ "No state."
      assert count(html, "#note.alert-error") == 0
    end
  end

  describe "error_kind/1" do
    test "treats a missing state as information, everything else as an error" do
      assert ProcessInfoComponents.error_kind(:no_state) == :info
      assert ProcessInfoComponents.error_kind(:timeout) == :error
    end
  end

  describe "identifier_chips/1" do
    test "renders an empty marker without items" do
      assert text(chips([]), "#chips") =~ "None"
    end

    test "links pids of the inspected node in their local form" do
      html = chips(items: [remote_pid()], total: 1)

      assert attr(html, "#chips a", "href") == ["/node/demo%40127.0.0.1/processes/%3C0.45.6%3E"]
      assert text(html, "#chips a") =~ "<0.45.6>"
    end

    test "renders pids of other nodes as plain text with their node" do
      html = chips(items: [self()], total: 1)

      assert count(html, "#chips a") == 0
      assert text(html, "#chips span") =~ "on nonode@nohost"
    end

    test "unwraps monitor entries and lists non-pid targets plainly" do
      port = Port.open({:spawn, "cat"}, [:binary])
      on_exit(fn -> if Port.info(port), do: Port.close(port) end)

      html =
        chips(
          items: [{:process, remote_pid()}, {:port, port}, {:name, :other@node}],
          total: 3
        )

      assert count(html, "#chips a") == 1
      assert text(html, "#chips") =~ ":name on other@node"
    end

    test "shows how many entries stayed on the remote" do
      html = chips(items: [remote_pid()], total: 5)

      assert text(html, "#chips") =~ "+4 more on the remote node"
    end
  end

  describe "bounded_count/1" do
    test "formats totals from bounded maps and ok async results" do
      assert ProcessInfoComponents.bounded_count(%{total: 1234}) == "(1,234)"

      assert ProcessInfoComponents.bounded_count(AsyncResult.ok(%{total: 2})) == "(2)"
    end

    test "is nil while nothing is loaded" do
      assert ProcessInfoComponents.bounded_count(nil) == nil
      assert ProcessInfoComponents.bounded_count(AsyncResult.loading()) == nil
    end
  end

  describe "loading?/1" do
    test "tracks the async loading flag" do
      assert ProcessInfoComponents.loading?(AsyncResult.loading())
      refute ProcessInfoComponents.loading?(AsyncResult.ok(:x))
      refute ProcessInfoComponents.loading?(nil)
    end
  end
end

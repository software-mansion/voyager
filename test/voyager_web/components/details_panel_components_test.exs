defmodule VoyagerWeb.Components.DetailsPanelComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.AsyncResult
  alias Voyager.EtsFakes
  alias VoyagerWeb.Components.DetailsPanelComponents
  alias VoyagerWeb.Components.EtsTableComponents
  alias VoyagerWeb.Components.ProcessComponents
  alias VoyagerWeb.Components.SupervisionTreeComponents
  alias VoyagerWeb.EtsTableHelp
  alias VoyagerWeb.FormSchemas.EtsTableListControls
  alias VoyagerWeb.FormSchemas.ProcessListControls
  alias VoyagerWeb.ProcessInfoHelp

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  describe "kv/1" do
    test "renders a help tooltip with the doc link when a help entry is given" do
      html =
        render_component(&DetailsPanelComponents.kv/1,
          label: "Reductions",
          value: "1,024",
          help: ProcessInfoHelp.get(:reductions)
        )

      assert count(html, "#kv-help-Reductions") == 1
      assert html =~ ~s|href="#{ProcessInfoHelp.get(:reductions).doc_href}"|
    end

    test "the loading skeleton keeps the help tooltip" do
      html =
        render_component(&DetailsPanelComponents.kv_skeleton/1,
          label: "Reductions",
          help: ProcessInfoHelp.get(:reductions)
        )

      assert count(html, "#kv-help-Reductions") == 1
    end

    test "renders no tooltip without a help entry" do
      html = render_component(&DetailsPanelComponents.kv/1, label: "Reductions", value: "1")

      assert count(html, "[id^=kv-help-]") == 0
    end
  end

  describe "section/1" do
    test "renders the relation legend as a help tooltip" do
      html =
        render_component(&DetailsPanelComponents.section/1,
          title: "Monitored by",
          help: SupervisionTreeComponents.edge_legend("Monitored by"),
          inner_block: []
        )

      assert count(html, "#section-help-Monitored-by") == 1
      assert html =~ SupervisionTreeComponents.edge_legend("Monitored by").doc_href
    end
  end

  describe "ETS columns/1" do
    test "gives every column a help entry" do
      columns =
        EtsTableComponents.columns(
          EtsTableListControls.required_columns() ++ EtsTableListControls.optional_columns()
        )

      assert Enum.all?(columns, &match?(%{help: %{text: _}}, &1))
    end
  end

  describe "process columns/1" do
    test "gives every column a help entry" do
      columns =
        ProcessComponents.columns(
          ProcessListControls.required_columns() ++ ProcessListControls.optional_columns()
        )

      assert Enum.all?(columns, &match?(%{help: %{text: _}}, &1))
    end
  end

  describe "overview/1" do
    defp render_overview(attrs) do
      info = %{
        initial_call: {:gen_server, :init_it, 6},
        current_function: {:gen_server, :loop, 7},
        current_stacktrace: [],
        registered_name: :demo,
        label: :undefined,
        parent: self(),
        status: :waiting,
        message_queue_len: 0,
        message_queue_data: :on_heap,
        group_leader: self(),
        priority: :normal,
        trap_exit: false,
        reductions: 1,
        last_calls: false,
        catch_level: 0,
        trace: 0,
        suspending: [],
        sequential_trace_token: [],
        error_handler: :error_handler
      }

      defaults = [
        info: AsyncResult.ok(info),
        remote_node: node(),
        panel_id: "panel",
        on_select: "select-link"
      ]

      render_component(&DetailsPanelComponents.overview/1, Keyword.merge(defaults, attrs))
    end

    test "linkable pids jump in the tree" do
      html = render_overview([])

      assert count(html, "button#panel-parent[phx-click=select-link]") == 1
      assert count(html, "button#panel-group_leader[phx-click=select-link]") == 1
      assert count(html, "a") == 0
    end

    test "pids on another node are plain text" do
      html = render_overview(remote_node: :other@host)

      assert count(html, "[phx-click=select-link]") == 0
      assert count(html, "a") == 0
    end

    test "linkable pids are plain process links with current_url" do
      html = render_overview(current_url: "http://localhost/node/demo%40127.0.0.1/processes/x")

      assert count(html, "[phx-click=select-link]") == 0
      assert count(html, "a.text-primary") == 2
    end
  end

  describe "ETS details_panel/1" do
    test "renders a help tooltip on every table property row" do
      html =
        render_component(&EtsTableComponents.details_panel/1,
          id: "ets-panel",
          table_param: "t",
          table: EtsFakes.table(),
          fetch_status: :fetched,
          current_url: "http://localhost/node/demo%40127.0.0.1/ets-tables",
          contents_href: nil
        )

      assert count(html, "[phx-hook=Tooltip][id^=kv-help-]") == 12
      assert html =~ ~s|href="#{EtsTableHelp.get(:read_concurrency).doc_href}"|
    end
  end
end

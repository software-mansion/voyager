defmodule VoyagerWeb.Components.DetailsPanelComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Voyager.EtsFakes
  alias VoyagerWeb.Components.DetailsPanelComponents
  alias VoyagerWeb.Components.EtsTableComponents
  alias VoyagerWeb.EtsTableHelp
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

    test "renders no tooltip without a help entry" do
      html = render_component(&DetailsPanelComponents.kv/1, label: "Reductions", value: "1")

      assert count(html, "[id^=kv-help-]") == 0
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
          owner_href: "/owner",
          contents_href: nil
        )

      assert count(html, "[phx-hook=Tooltip][id^=kv-help-]") == 12
      assert html =~ ~s|href="#{EtsTableHelp.get(:read_concurrency).doc_href}"|
    end
  end
end

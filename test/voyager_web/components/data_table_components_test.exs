defmodule VoyagerWeb.Components.DataTableComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias VoyagerWeb.Components.DataTableComponents

  @columns [
    %{key: :name, label: "Name", sortable?: false, align: :left},
    %{key: :memory, label: "Memory", sortable?: true, align: :right, width: :sm}
  ]

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> query(selector) |> Enum.count()
  defp text(html, selector), do: html |> query(selector) |> LazyHTML.text()
  defp attr(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)

  # The slot renders the row's value for the column, so a cell can be checked
  # for both which column it belongs to and what it was handed.
  defp cell_slot do
    [
      %{
        __slot__: :cell,
        inner_block: fn _changed, %{column: column, row: row} -> row[column.key] end
      }
    ]
  end

  defp table(attrs) do
    defaults = [id: "t", columns: @columns, rows: [], sort_by: :memory, direction: :desc]

    render_component(
      &DataTableComponents.table/1,
      defaults |> Keyword.merge(attrs) |> Keyword.put(:cell, cell_slot())
    )
  end

  defp pager(attrs) do
    render_component(
      &DataTableComponents.pager/1,
      Keyword.merge([id: "p", page: 1, page_size: 10, total: 25], attrs)
    )
  end

  describe "table/1" do
    test "renders a header per column, sortable ones as sort buttons" do
      html = table([])

      assert count(html, "thead th") == 2

      assert count(
               html,
               ~s|th[data-column="memory"] button[phx-click="sort"][phx-value-key="memory"]|
             ) == 1

      assert count(html, ~s|th[data-column="name"] button|) == 0
    end

    test "marks only the active sort column with its direction" do
      assert attr(table([]), ~s|th[data-column="memory"]|, "aria-sort") == ["descending"]

      assert attr(table(direction: :asc), ~s|th[data-column="memory"]|, "aria-sort") == [
               "ascending"
             ]

      assert attr(table(sort_by: :name), ~s|th[data-column="memory"]|, "aria-sort") == ["none"]
    end

    test "shows the empty message across every column when there are no rows" do
      html = table(empty_message: "Nothing here")

      assert text(html, "tbody td") =~ "Nothing here"
      assert attr(html, "tbody td", "colspan") == ["2"]
    end

    test "renders a row per tuple, with the slot filling each column" do
      html = table(rows: [{"row-1", %{name: "alpha", memory: 42}}])

      assert count(html, "tbody tr#row-1") == 1
      assert count(html, "tbody td") == 2
      assert text(html, ~s|#row-1 td[data-column="name"]|) =~ "alpha"
      assert text(html, ~s|#row-1 td[data-column="memory"]|) =~ "42"
    end
  end

  describe "pager/1" do
    test "reports the visible range of the total" do
      assert text(pager([]), "#p p") =~ "1–10"
      assert text(pager(page: 3), "#p p") =~ "21–25"
      assert text(pager(total: 0), "#p p") =~ "0–0"
    end

    test "hides the page buttons when everything fits on one page" do
      assert count(pager(total: 5), "#p-next") == 0
      assert count(pager([]), "#p-next") == 1
    end

    test "disables prev on the first page and next on the last" do
      first = pager([])
      assert count(first, "#p-prev[disabled]") == 1
      assert count(first, "#p-next[disabled]") == 0
      assert attr(first, "#p-next", "phx-value-page") == ["2"]

      last = pager(page: 3)
      assert count(last, "#p-prev[disabled]") == 0
      assert count(last, "#p-next[disabled]") == 1
      assert attr(last, "#p-prev", "phx-value-page") == ["2"]
    end

    test "offers a rows-per-page selector only when given options" do
      assert count(pager([]), "#p-page-size-form") == 0

      html = pager(page_size_options: [10, 25])
      assert attr(html, "#p-page-size-form", "phx-change") == ["set_page_size"]
      assert attr(html, "#p-page-size option[selected]", "value") == ["10"]
    end
  end
end

defmodule Voyager.E2E.EtsTablesTest do
  use Voyager.E2E.Case, async: true, project: "ets"

  # Tables owned by mock_ets_owner on the target node (see e2e/mock_app). The node runs
  # without Elixir, so the auto term syntax shows them as Erlang atoms.
  @cache "mock_ets_cache"
  @events "mock_ets_events"
  @secrets "mock_ets_secrets"
  @unnamed "mock_ets_unnamed"

  @rows "#ets-tables-table tbody tr[id]"
  @summary "#ets-tables-summary"
  @search "#controls_search"
  @protection "#controls_protection"
  @type_select "#controls_type"
  @named "#controls_named"
  @columns_picker "#ets-table-controls-columns"
  @panel "#ets-table-details"
  @panel_name "#ets-table-details-name"
  @panel_not_found "#ets-table-details-not-found"
  @panel_private_badge "#ets-table-details-private-badge"

  defp list_url, do: "/node/#{node_name()}/ets-tables"

  defp row(page, name) do
    page
    |> Page.locator(@rows)
    |> Locator.filter(has: Page.locator(page, ~s|td[data-column="name"]|, has_text: name))
  end

  defp style(locator) do
    Locator.evaluate!(locator, """
    (el) => {
      const { color, fontWeight } = getComputedStyle(el);
      return { color, fontWeight: Number(fontWeight) };
    }
    """)
  end

  # Narrows the list to the four mock_ets_* tables the mock app owns.
  defp filter_to_mock_tables(page) do
    Locator.fill!(Page.locator(page, @search), "mock_ets")
    Expect.to_have_count!(Page.locator(page, @rows), 4)
  end

  describe "EtsTablesLive" do
    setup %{page: page} do
      ensure_connected(page)
      Page.goto!(page, list_url())
      wait_for_live_view(page)
      page |> Page.locator(@rows) |> Locator.first() |> Expect.to_be_visible!()
      :ok
    end

    test "lists the node tables with a fetch summary", %{page: page} do
      Expect.to_contain_text!(Page.locator(page, @summary), ~r/Fetched \d+\s+tables/)
      Expect.to_contain_text!(Page.locator(page, @summary), "in total")

      # System tables of any BEAM node, fetched for real over :erpc.
      filter_to_mock_tables(page)
      Locator.fill!(Page.locator(page, @search), "ac_tab")
      Expect.to_have_count!(row(page, "ac_tab"), 1)
    end

    test "search narrows the rows and the summary reports it", %{page: page} do
      filter_to_mock_tables(page)

      Expect.to_contain_text!(Page.locator(page, @summary), ~r/Showing 4\s+of \d+/)
      Expect.to_be_visible!(row(page, @cache))
      Expect.to_be_visible!(row(page, @events))
      Expect.to_be_visible!(row(page, @secrets))
      Expect.to_be_visible!(row(page, @unnamed))

      # The metadata the mock app created the tables with.
      Expect.to_contain_text!(row(page, @cache), "public")
      Expect.to_contain_text!(row(page, @cache), "set")
      Expect.to_contain_text!(row(page, @cache), "100")
      Expect.to_contain_text!(row(page, @events), "duplicate_bag")
      Expect.to_contain_text!(row(page, @secrets), "private")

      row(page, @unnamed)
      |> Locator.locator(~s|td[data-column="name"] a|)
      |> Expect.to_have_attribute!("href", ~r/%23Reference/)
    end

    test "the selects filter by protection, type and named", %{page: page} do
      filter_to_mock_tables(page)

      page |> Page.locator(@protection) |> Locator.click!()
      page |> Page.locator("#controls_protection-private-option") |> Locator.click!()
      Expect.to_have_count!(Page.locator(page, @rows), 2)
      Expect.to_be_visible!(row(page, @secrets))
      Expect.to_be_visible!(row(page, @unnamed))

      page |> Page.locator(@type_select) |> Locator.click!()
      page |> Page.locator("#controls_type-ordered_set-option") |> Locator.click!()
      Expect.to_have_count!(Page.locator(page, @rows), 1)
      Expect.to_be_visible!(row(page, @secrets))

      page |> Page.locator(@type_select) |> Locator.click!()
      page |> Page.locator("#controls_type-blank-option") |> Locator.click!()
      page |> Page.locator(@named) |> Locator.click!()
      page |> Page.locator("#controls_named-false-option") |> Locator.click!()
      Expect.to_have_count!(Page.locator(page, @rows), 1)
      Expect.to_be_visible!(row(page, @unnamed))
    end

    test "clicking the already-selected option closes the select", %{page: page} do
      page |> Page.locator(@protection) |> Locator.click!()
      Expect.to_be_visible!(Page.locator(page, "#controls_protection-blank-option"))

      page |> Page.locator("#controls_protection-blank-option") |> Locator.click!()
      Expect.to_be_hidden!(Page.locator(page, "#controls_protection-blank-option"))
      Expect.to_be_focused!(Page.locator(page, @protection))
    end

    test "escape closes the select and returns focus to the trigger", %{page: page} do
      page |> Page.locator(@protection) |> Locator.click!()
      page |> Page.locator("#controls_protection-private-option input") |> Locator.focus!()
      Keyboard.press!(Page.keyboard(page), "Escape")

      Expect.to_be_hidden!(Page.locator(page, "#controls_protection-private-option"))
      Expect.to_be_focused!(Page.locator(page, @protection))
    end

    test "clicking outside an open select closes it", %{page: page} do
      page |> Page.locator(@protection) |> Locator.click!()
      Expect.to_be_visible!(Page.locator(page, "#controls_protection-private-option"))

      page |> Page.locator(@search) |> Locator.click!()
      Expect.to_be_hidden!(Page.locator(page, "#controls_protection-private-option"))
      Expect.to_be_focused!(Page.locator(page, @search))
    end

    test "sorts by a clicked column locally", %{page: page} do
      filter_to_mock_tables(page)

      page |> Page.locator(~s|button[phx-value-key="name"]|) |> Locator.click!()

      page
      |> Page.locator(~s|th[data-column="name"]|)
      |> Expect.to_have_attribute!("aria-sort", "ascending")

      names = Page.locator(page, "#{@rows} td[data-column=\"name\"]")
      names |> Locator.first() |> Expect.to_contain_text!(@cache)
      names |> Locator.last() |> Expect.to_contain_text!(@unnamed)

      page |> Page.locator(~s|button[phx-value-key="name"]|) |> Locator.click!()

      page
      |> Page.locator(~s|th[data-column="name"]|)
      |> Expect.to_have_attribute!("aria-sort", "descending")

      names |> Locator.first() |> Expect.to_contain_text!(@unnamed)
    end

    test "the columns picker hides and reveals optional columns", %{page: page} do
      Expect.to_be_visible!(Page.locator(page, ~s|th[data-column="type"]|))
      Expect.to_have_count!(Page.locator(page, ~s|th[data-column="heir"]|), 0)

      page |> Page.locator(@columns_picker) |> Locator.click!()
      page |> Page.locator("#ets-table-controls-columns-type-input") |> Locator.uncheck!()
      page |> Page.locator("#ets-table-controls-columns-heir-input") |> Locator.check!()

      Expect.to_have_count!(Page.locator(page, ~s|th[data-column="type"]|), 0)
      Expect.to_be_visible!(Page.locator(page, ~s|th[data-column="heir"]|))
      Expect.to_be_visible!(Page.locator(page, ~s|th[data-column="name"]|))
      Expect.to_be_visible!(Page.locator(page, ~s|th[data-column="memory"]|))
    end

    test "selecting a table opens the side panel with its full metadata", %{page: page} do
      filter_to_mock_tables(page)

      row(page, @cache) |> Locator.locator(~s|td[data-column="name"] a|) |> Locator.click!()
      Expect.to_contain_text!(Page.locator(page, @panel_name), @cache)
      Expect.to_have_url!(page, ~r/table=/)

      Expect.to_contain_text!(Page.locator(page, @panel), "Key position")
      Expect.to_contain_text!(Page.locator(page, @panel), "Read concurrency")
      Expect.to_contain_text!(Page.locator(page, @panel), "set")
    end

    test "a private table is marked in the list and the panel", %{page: page} do
      filter_to_mock_tables(page)
      Expect.to_contain_text!(row(page, @secrets), "private")

      row(page, @secrets) |> Locator.locator(~s|td[data-column="name"] a|) |> Locator.click!()
      Expect.to_be_visible!(Page.locator(page, @panel_private_badge))
      Expect.to_contain_text!(Page.locator(page, @panel), "ordered_set")
    end

    test "an unknown table is reported in the panel", %{page: page} do
      Page.goto!(page, "#{list_url()}?table=no_such_table_here")
      wait_for_live_view(page)

      Expect.to_be_visible!(Page.locator(page, @panel_not_found))
    end
  end

  describe "EtsTableLive" do
    setup %{page: page} do
      ensure_connected(page)
      Page.goto!(page, "#{list_url()}/#{URI.encode_www_form(@cache)}")
      wait_for_live_view(page)
      page |> Page.locator("#ets-peek-fetch") |> Locator.click!()
      Expect.to_be_visible!(Page.locator(page, "#ets-records-0"))
      :ok
    end

    test "the record key stands out in the row preview", %{page: page} do
      key = Page.locator(page, "#ets-records-0-key")
      Expect.to_be_visible!(key)

      key_style = style(key)
      row_style = key |> Locator.locator("..") |> style()
      refute key_style["color"] == row_style["color"]
      assert key_style["fontWeight"] > row_style["fontWeight"]
    end
  end

  describe "EtsTableLive on a plain Erlang node" do
    test "shows the table name and records in Erlang syntax", %{page: page} do
      ensure_connected(page)
      Page.goto!(page, "#{list_url()}/#{URI.encode_www_form(":#{@events}")}")
      wait_for_live_view(page)
      page |> Page.locator("#ets-peek-fetch") |> Locator.click!()

      Expect.to_have_text!(Page.locator(page, "#ets-table-name"), @events)
      Expect.to_contain_text!(Page.locator(page, "#ets-records-0"), "{event, ")

      page
      |> Page.locator("#ets-records-0")
      |> Expect.not_()
      |> Expect.to_contain_text!(":event")
    end
  end
end

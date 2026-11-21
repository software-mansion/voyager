defmodule Voyager.E2E.RecentConnectionsTest do
  use Voyager.E2E.Case, async: false, project: "recent-connections"

  # The tests depend on each other's state, so they run in definition order (`--seed 0`, see the
  # `e2e` alias). The module sets up its own connection, whatever ran before it.
  setup_all %{browser: browser} do
    page = Browser.new_page!(browser)
    ensure_connected(page)
    Page.close!(page)
    :ok
  end

  describe "ConnectLive › recent connections" do
    test "shows recent connection and disables fill while connected", %{page: page} do
      Page.goto!(page, "/")
      wait_for_live_view(page)

      Expect.to_be_visible!(Page.locator(page, sel(:recent_connections)))
      Expect.to_contain_text!(Page.locator(page, sel(:recent_connections)), node_name())
      Expect.to_be_visible!(Page.locator(page, sel(:disconnect_from_connect)))
      Expect.to_be_disabled!(Page.locator(page, sel(:connect_btn)))
      page |> fill_recent_btn() |> Locator.first() |> Expect.to_be_disabled!()
    end

    test "disconnects from the connect page and re-enables the form", %{page: page} do
      Page.goto!(page, "/")
      wait_for_live_view(page)
      Locator.click!(Page.locator(page, sel(:disconnect_from_connect)))

      Expect.to_be_hidden!(Page.locator(page, sel(:disconnect_from_connect)))
      Expect.to_be_enabled!(Page.locator(page, sel(:connect_btn)))
      page |> fill_recent_btn() |> Locator.first() |> Expect.to_be_enabled!()
    end

    test "fills the form from a recent connection row", %{page: page} do
      ensure_disconnected(page)

      page |> fill_recent_btn() |> Locator.first() |> Locator.click!()
      Expect.to_have_value!(Page.locator(page, sel(:node_name_input)), node_name())
    end
  end
end

defmodule Voyager.E2E.ConnectTest do
  use Voyager.E2E.Case,
    async: false,
    projects: [{"connect", "Desktop Chrome"}]

  # Each test starts from `ensure_disconnected/1`, so the order doesn't matter.
  describe "direct connect" do
    test "connects to an IPv6 node and disconnects", %{page: page} do
      ensure_disconnected(page)
      fill_connect_form(page, node_name_v6(), cookie())
      Locator.click!(Page.locator(page, sel(:connect_btn)))
      Expect.to_have_url!(page, ~r"/node/")
      ensure_disconnected(page)
    end

    test "connects to node and navigates to node page", %{page: page} do
      ensure_disconnected(page)
      fill_connect_form(page, node_name(), cookie())
      Locator.click!(Page.locator(page, sel(:connect_btn)))
      Expect.to_have_url!(page, ~r"/node/")
    end
  end
end

defmodule Voyager.E2E.SidebarTest do
  use Voyager.E2E.Case, async: true, project: "sidebar"

  @sidebar "#app-sidebar"

  describe "Sidebar" do
    setup %{page: page} do
      ensure_connected(page)
      Page.goto!(page, "/node/#{node_name()}")
      Expect.to_be_visible!(Page.locator(page, @sidebar))
      :ok
    end

    test "Cmd/Ctrl+B toggles the sidebar width and remembers it", %{page: page} do
      html = Page.locator(page, "html")
      keyboard = Page.keyboard(page)

      Keyboard.press!(keyboard, "ControlOrMeta+b")
      Expect.to_have_attribute!(html, "data-sidebar", "compact")

      page |> Page.locator("#sidebar-nav-processes") |> Locator.click!()
      Expect.to_have_url!(page, ~r"/processes")
      Expect.to_have_attribute!(html, "data-sidebar", "compact")

      Page.reload!(page)
      Expect.to_have_attribute!(html, "data-sidebar", "compact")

      Keyboard.press!(keyboard, "ControlOrMeta+b")
      Expect.to_have_attribute!(html, "data-sidebar", "full")
    end
  end
end

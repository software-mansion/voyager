defmodule Voyager.E2E.DetailsPanelTest do
  use Voyager.E2E.Case,
    async: true,
    project: "supervision-tree",
    group: :details_panel_spec

  import Voyager.E2E.TreeHelpers

  describe "SupervisionTreeLive › DetailsPanel" do
    setup %{page: page} do
      Page.add_init_script!(page, "localStorage.removeItem('voyager:details-panel-width')")
      open_tree(page)
      :ok
    end

    test "selecting a node via cytoscape emit opens the details panel", %{page: page} do
      panel = Page.locator(page, "#details-panel")

      Expect.to_have_class!(panel, ~r/translate-x-full/)

      select_node(page, "mock_root_sup")

      Expect.to_have_class!(panel, ~r/translate-x-0/)
      Expect.to_contain_text!(panel, "Supervisor")
      Expect.to_contain_text!(panel, "mock_root_sup")
    end

    test "resizing the panel updates its width", %{page: page} do
      select_node(page, "mock_root_sup")

      panel = Page.locator(page, "#details-panel")
      Expect.to_have_class!(panel, ~r/translate-x-0/)
      Expect.to_be_visible!(Page.locator(page, "#details-panel-resize-handle"))

      before = details_panel_css_width(page)
      resize_details_panel(page, 100)

      Expect.to_pass!(fn ->
        assert details_panel_css_width(page) > before + 40
      end)

      stored = Page.evaluate!(page, "() => localStorage.getItem('voyager:details-panel-width')")
      {width, _} = Float.parse(stored || "")
      assert width > before + 40
    end

    test "emitting select-node with empty key closes the details panel", %{page: page} do
      select_node(page, "mock_root_sup")

      panel = Page.locator(page, "#details-panel")
      Expect.to_have_class!(panel, ~r/translate-x-0/)

      clear_selection(page)

      Expect.to_have_class!(panel, ~r/translate-x-full/)
    end

    test "clicking a pid link selects that process in the details panel", %{page: page} do
      select_node(page, "mock_root_sup")

      panel = Page.locator(page, "#details-panel")
      Expect.to_have_class!(panel, ~r/translate-x-0/)

      chip = panel |> Locator.locator(~s|button[id^="details-panel-links-"]|) |> Locator.first()
      Expect.to_be_enabled!(chip)

      label = chip |> Locator.inner_text!() |> String.trim()
      Locator.click!(chip)

      Expect.to_have_class!(panel, ~r/translate-x-0/)
      panel |> Locator.locator("#details-panel-pid") |> Expect.to_have_text!(label)
      Expect.to_be_visible!(Page.locator(page, "#details-panel-back"))

      page |> Page.locator("#details-panel-back") |> Locator.click!()

      Expect.to_contain_text!(panel, "mock_root_sup")
      Expect.to_have_count!(Page.locator(page, "#details-panel-back"), 0)
    end
  end
end

defmodule Voyager.E2E.DetailsPanelRelationOnlyLinkTest do
  use Voyager.E2E.Case,
    async: true,
    project: "supervision-tree",
    group: :details_panel_spec

  import Voyager.E2E.TreeHelpers

  setup_all do
    rpc_ok("mock_worker link_orphan [mock_static_worker, mock_orphan]")
    on_exit(fn -> rpc_ok("mock_worker clear_relations [mock_static_worker]") end)
    :ok
  end

  describe "SupervisionTreeLive › DetailsPanel › relation-only link" do
    test "clicking a link to it reveals it under a collapsed source", %{page: page} do
      open_tree(page)
      select_node(page, "mock_static_worker")
      orphan_key = node_key(page, "mock_orphan")

      click_toggle(page, "mock_root_sup")

      Expect.poll!(fn -> cy_node(page, "mock_orphan") end, &assert(%{"hidden" => true} = &1))

      page |> Page.locator(~s|#details-panel [phx-value-key="#{orphan_key}"]|) |> Locator.click!()

      page |> Page.locator("#details-panel") |> Expect.to_contain_text!("mock_orphan")

      Expect.poll!(fn -> cy_node(page, "mock_orphan") end, &assert(%{"hidden" => false} = &1))
    end
  end
end

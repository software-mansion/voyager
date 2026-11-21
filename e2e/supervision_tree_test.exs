defmodule Voyager.E2E.SupervisionTreeTest do
  use Voyager.E2E.Case,
    async: true,
    project: "supervision-tree",
    group: :supervision_tree_spec

  import Voyager.E2E.TreeHelpers

  # The graph is a cytoscape canvas: nodes are not DOM elements. Tests interact
  # through the .cy-toggle overlay buttons and assert deeper state via cy_node/2
  # (the cytoscape instance exposed by the hook). The mock_app tree served by
  # the target node (see e2e/mock_app/) looks like:
  #
  #   app:mock_app (app's master process)
  #   |
  #   +-- p (intermediate process)
  #       |
  #       +-- mock_root_sup
  #           +-- mock_static_worker
  #           +-- mock_deep_sup_1 -- mock_deep_sup_2 -- mock_deep_sup_3 -- mock_leaf_worker
  #           +-- mock_rel_sup_a -- mock_rel_deep_sup_a -- mock_rel_leaf_a
  #           +-- mock_rel_sup_b -- mock_rel_deep_sup_b -- mock_rel_leaf_b
  #           +-- mock_dyn_sup_a        (0 children; tests add some at runtime)
  #           +-- mock_dyn_sup_b        (1 child: mock_dyn_worker_b1)
  #
  # At the default walk depth (3) every supervisor child of mock_root_sup is a
  # collapsed stub. Timing rules: never assert the loading->ok transition (it
  # races the 5 s auto-refresh) and never chain clicks without waiting for the
  # previous one's effect (layout animations swallow clicks).

  describe "SupervisionTreeLive › expand/collapse" do
    setup %{page: page} do
      rpc_ok("mock_app_ctl reset []")
      open_tree(page)
      :ok
    end

    test "renders stubs beyond depth as collapsed", %{page: page} do
      Expect.to_have_attribute!(toggle(page, "mock_deep_sup_1"), "data-collapsed", "true")
      assert cy_node(page, "mock_deep_sup_2") == %{"exists" => false}

      # No toggle for a 0-child supervisor nor for a worker leaf.
      Expect.to_have_count!(toggle(page, "mock_dyn_sup_a"), 0)
      Expect.to_have_count!(toggle(page, "mock_static_worker"), 0)

      Expect.to_have_attribute!(toggle(page, "mock_dyn_sup_b"), "data-collapsed", "true")
      dyn_sup_b = cy_node(page, "mock_dyn_sup_b")
      assert dyn_sup_b["exists"] and dyn_sup_b["label"] =~ "(1)"
    end

    test "expanding a stub loads its children", %{page: page} do
      click_toggle(page, "mock_deep_sup_1")

      Expect.to_have_attribute!(toggle(page, "mock_deep_sup_2"), "data-collapsed", "true")

      assert %{
               "exists" => true,
               "hidden" => false,
               "childCount" => 1
             } = cy_node(page, "mock_deep_sup_2")
    end

    test "collapsing hides loaded descendants without a refetch", %{page: page} do
      click_toggle(page, "mock_deep_sup_1")
      Expect.to_be_visible!(toggle(page, "mock_deep_sup_2"))

      click_toggle(page, "mock_deep_sup_1")

      Expect.to_pass!(fn ->
        assert %{"exists" => true, "hidden" => true} = cy_node(page, "mock_deep_sup_2")
      end)

      Expect.to_be_hidden!(toggle(page, "mock_deep_sup_2"))
    end

    test "re-expanding reveals the previously collapsed subtree", %{page: page} do
      click_toggle(page, "mock_deep_sup_1")
      Expect.to_be_visible!(toggle(page, "mock_deep_sup_2"))
      click_toggle(page, "mock_deep_sup_1")
      Expect.to_be_hidden!(toggle(page, "mock_deep_sup_2"))

      click_toggle(page, "mock_deep_sup_1")

      Expect.to_be_visible!(toggle(page, "mock_deep_sup_2"))

      assert %{
               "exists" => true,
               "hidden" => false,
               "hiddenCount" => 0
             } = cy_node(page, "mock_deep_sup_2")
    end

    # Uses mock_root_sup (kept in every walk by the depth setting, so refetches
    # never prune its subtree) and the mock_app application node (not a real
    # pid, so its toggle is purely client-side). This makes the client-only
    # hidden_count bookkeeping observable without racing the auto-refresh.
    test "a node under two collapsed ancestors stays hidden until both expand", %{page: page} do
      # collapse inner
      click_toggle(page, "mock_root_sup")
      # collapse outer
      click_toggle(page, "app:mock_app")
      # re-expand outer only
      click_toggle(page, "app:mock_app")

      Expect.to_pass!(fn ->
        focus_node(page, "mock_root_sup")

        Expect.to_have_attribute!(toggle(page, "mock_root_sup"), "data-collapsed", "true",
          timeout: 1_000
        )
      end)

      # Still hidden by the collapsed mock_root_sup.
      assert %{
               "exists" => true,
               "hidden" => true,
               "hiddenCount" => 1
             } = cy_node(page, "mock_deep_sup_1")
    end

    test "collapsing an expanded node prunes its loaded children on refetch", %{page: page} do
      click_toggle(page, "mock_deep_sup_1")
      Expect.to_be_visible!(toggle(page, "mock_deep_sup_2"))
      click_toggle(page, "mock_deep_sup_2")
      Expect.to_be_visible!(toggle(page, "mock_deep_sup_3"))

      # collapse inner
      click_toggle(page, "mock_deep_sup_2")
      # collapse outer
      click_toggle(page, "mock_deep_sup_1")
      # re-expand outer only
      click_toggle(page, "mock_deep_sup_1")

      # Re-expanding refetches; mock_deep_sup_2 is no longer expanded on the
      # server, so it returns as a collapsed stub and its subtree is removed.
      Expect.to_pass!(fn ->
        focus_node(page, "mock_deep_sup_2")

        Expect.to_have_attribute!(toggle(page, "mock_deep_sup_2"), "data-collapsed", "true",
          timeout: 1_000
        )

        assert cy_node(page, "mock_deep_sup_3") == %{"exists" => false}
      end)
    end

    # A node that gains children at
    # runtime must recompute its collapsed state from the delta patch.
    test "a childless supervisor gaining a child gets a working + toggle", %{page: page} do
      Expect.to_have_count!(toggle(page, "mock_dyn_sup_a"), 0)

      rpc_ok("mock_app_ctl add_child [mock_dyn_sup_a, tmp_a1]")

      refreshed(page, fn ->
        Expect.to_have_attribute!(toggle(page, "mock_dyn_sup_a"), "data-collapsed", "true",
          timeout: 1_000
        )
      end)

      sup = cy_node(page, "mock_dyn_sup_a")
      assert sup["exists"] and sup["label"] =~ "(1)"

      click_toggle(page, "mock_dyn_sup_a")

      Expect.to_pass!(fn ->
        assert %{"exists" => true, "hidden" => false} = cy_node(page, "tmp_a1")
      end)
    end

    # An already-expanded node gaining another child must
    # stay expanded instead of flipping back to +.
    test "an expanded supervisor gaining a child stays expanded", %{page: page} do
      click_toggle(page, "mock_dyn_sup_b")

      Expect.to_pass!(fn ->
        assert %{"exists" => true, "hidden" => false} = cy_node(page, "mock_dyn_worker_b1")
      end)

      rpc_ok("mock_app_ctl add_child [mock_dyn_sup_b, tmp_b2]")

      refreshed(page, fn ->
        assert %{"exists" => true, "hidden" => false} = cy_node(page, "tmp_b2")
      end)

      Expect.to_have_attribute!(toggle(page, "mock_dyn_sup_b"), "data-collapsed", "false")
      sup = cy_node(page, "mock_dyn_sup_b")
      assert sup["exists"] and sup["label"] =~ "(2)"
    end

    test "removing the last child drops the node and its toggle", %{page: page} do
      rpc_ok("mock_app_ctl add_child [mock_dyn_sup_a, tmp_a1]")

      refreshed(page, fn ->
        Expect.to_be_visible!(toggle(page, "mock_dyn_sup_a"), timeout: 1_000)
      end)

      click_toggle(page, "mock_dyn_sup_a")

      Expect.to_pass!(fn ->
        assert %{"exists" => true} = cy_node(page, "tmp_a1")
      end)

      rpc_ok("mock_app_ctl remove_child [mock_dyn_sup_a, tmp_a1]")

      refreshed(page, fn ->
        assert cy_node(page, "tmp_a1") == %{"exists" => false}
      end)

      Expect.to_be_hidden!(toggle(page, "mock_dyn_sup_a"))
    end

    test "changing depth resets manual expansion", %{page: page} do
      click_toggle(page, "mock_deep_sup_1")
      Expect.to_be_visible!(toggle(page, "mock_deep_sup_2"))
      click_toggle(page, "mock_deep_sup_2")
      Expect.to_be_visible!(toggle(page, "mock_deep_sup_3"))

      page |> Page.locator(~s|input[name="tree_controls[depth]"]|) |> Locator.fill!("4")

      # At depth 4 mock_deep_sup_2 is reached by the walk itself, but the manual
      # expansion of mock_deep_sup_2 is forgotten, so mock_deep_sup_3 is gone.
      Expect.to_pass!(fn -> assert cy_node(page, "mock_deep_sup_3") == %{"exists" => false} end,
        timeout: 1_000
      )

      Expect.to_pass!(fn ->
        focus_node(page, "mock_deep_sup_2")

        Expect.to_have_attribute!(toggle(page, "mock_deep_sup_2"), "data-collapsed", "true",
          timeout: 1_000
        )
      end)
    end
  end
end

# Regression coverage for PR #105 (floating nodes in the supervision tree).
# A relationship edge (here a monitor; link / monitored_by collapse the same
# way) can join two otherwise independent branches. Collapsing used to follow
# those relation edges as if they were part of the supervision spine, which
# collapsing the two branches one at a time produced two defects:
#
#   1. Collapsing one branch kept the relation *target* visible (correct) but
#      wrongly hid that target's own strict-supervision subtree in the other,
#      still-expanded branch, so after each collapse we assert the untouched
#      branch stays fully visible.
#   2. Once both joined branches were collapsed, a node was left "floating"
#      (still drawn but with every edge gone) instead of being hidden.
#
# The scenario runs across a matrix so every collapse path is covered:
#   * expansion: branches opened with the +/- toggle buttons, vs. opened
#     wholesale by raising the walk depth;
#   * order: collapse branch A first then B, vs. B first then A.
defmodule Voyager.E2E.SupervisionTreeRelationEdgeTest do
  use Voyager.E2E.Case,
    async: true,
    project: "supervision-tree",
    group: :supervision_tree_spec

  import Voyager.E2E.TreeHelpers

  @branch %{
    a: %{top: "mock_rel_sup_a", sup: "mock_rel_deep_sup_a", leaf: "mock_rel_leaf_a"},
    b: %{top: "mock_rel_sup_b", sup: "mock_rel_deep_sup_b", leaf: "mock_rel_leaf_b"}
  }

  setup_all do
    rpc_ok("mock_app_ctl reset []")
    # Two deep branches joined by a monitor between their leaves:
    rpc_ok("mock_worker monitor_process [mock_rel_leaf_a, mock_rel_leaf_b]")
    on_exit(fn -> rpc_ok("mock_worker clear_relations [mock_rel_leaf_a]") end)
    :ok
  end

  defp expand_branches(page, :toggle, branch) do
    # Open branch A first, then B, via the overlay toggle buttons.
    click_toggle(page, branch.a.top)
    Expect.to_be_visible!(toggle(page, branch.a.sup))
    click_toggle(page, branch.a.sup)
    click_toggle(page, branch.b.top)
    Expect.to_be_visible!(toggle(page, branch.b.sup))
    click_toggle(page, branch.b.sup)
  end

  defp expand_branches(page, :depth, _branch) do
    # Depth 5 reaches the leaves (app, p, root_sup, dyn_sup, rel_sup,
    # rel_leaf), so both branches open structurally at once.
    page |> Page.locator(~s|input[name="tree_controls[depth]"]|) |> Locator.fill!("5")
  end

  describe "SupervisionTreeLive › relation-edge collapse" do
    for expansion <- [:toggle, :depth], {first, second} <- [{:a, :b}, {:b, :a}] do
      test "keeps the other branch and never floats a node (#{expansion} expand, collapse #{first} then #{second})",
           %{page: page} do
        expansion = unquote(expansion)
        first = unquote(first)
        second = unquote(second)
        branch = @branch

        open_tree(page)

        expand_branches(page, expansion, branch)

        Expect.to_pass!(
          fn ->
            assert %{"exists" => true, "hidden" => false} = cy_node(page, branch.a.leaf)
            assert %{"exists" => true, "hidden" => false} = cy_node(page, branch.b.leaf)
          end,
          timeout: 5_000
        )

        # Guard: the collapses below only exercise the fix if the relation edge
        # actually joins the two branches.
        assert rel_edge(page, branch.a.leaf, branch.b.leaf, "monitor") == true

        # Focusing re-zooms the node into view so its overlay toggle exists
        # (depth-expanded trees fit too small for the buttons to render).
        collapse = fn key ->
          focus_node(page, branch[key].top)
          click_toggle(page, branch[key].top)
        end

        # Collapse the first branch: its supervisor hides, while the other
        # branch (reachable only through the relation edge) must stay fully
        # visible, and nothing floats.
        collapse.(first)

        Expect.to_pass!(
          fn ->
            assert %{"exists" => true, "hidden" => true} = cy_node(page, branch[first].sup)
            assert %{"exists" => true, "hidden" => false} = cy_node(page, branch[second].sup)
            assert %{"exists" => true, "hidden" => false} = cy_node(page, branch[second].leaf)
            assert floating_nodes(page) == []
          end,
          timeout: 3_000
        )

        # Collapse the second branch too: everything joined by the relation is
        # now hidden, nothing left floating.
        collapse.(second)

        Expect.to_pass!(
          fn ->
            assert %{"exists" => true, "hidden" => true} = cy_node(page, branch[first].leaf)
            assert %{"exists" => true, "hidden" => true} = cy_node(page, branch[second].leaf)
            assert floating_nodes(page) == []
          end,
          timeout: 3_000
        )
      end
    end
  end
end

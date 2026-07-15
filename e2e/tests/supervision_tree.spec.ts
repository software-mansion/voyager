import { test, expect } from '@playwright/test';
import {
  rpcOk,
  toggle,
  cyNode,
  relEdge,
  floatingNodes,
  openTree,
  clickToggle,
  focusNode,
  refreshed,
} from './supervision_tree_helpers';

// The graph is a cytoscape canvas: nodes are not DOM elements. Tests interact
// through the .cy-toggle overlay buttons and assert deeper state via cyNode()
// (the cytoscape instance exposed by the hook). The mock_app tree served by
// the target node (see e2e/mock_app/) looks like:
//
//   app:mock_app (app's master process)
//   └── p (intermediate process)
//       └── mock_root_sup
//           ├── mock_static_worker
//           ├── mock_deep_sup_1 ── mock_deep_sup_2 ── mock_deep_sup_3 ── mock_leaf_worker
//           ├── mock_dyn_sup_a        (0 children; tests add some at runtime)
//           └── mock_dyn_sup_b        (1 child: mock_dyn_worker_b1)
//
// At the default walk depth (3) every supervisor child of mock_root_sup is a
// collapsed stub. Timing rules: never assert the loading->ok transition (it
// races the 5 s auto-refresh) and never chain clicks without waiting for the
// previous one's effect (layout animations swallow clicks).

test.describe('SupervisionTreeLive › expand/collapse', () => {
  test.beforeEach(async ({ page }) => {
    rpcOk('mock_app_ctl reset []');
    await openTree(page);
  });

  test('renders stubs beyond depth as collapsed', async ({ page }) => {
    await expect(toggle(page, 'mock_deep_sup_1')).toHaveAttribute(
      'data-collapsed',
      'true'
    );
    expect(await cyNode(page, 'mock_deep_sup_2')).toEqual({ exists: false });

    // No toggle for a 0-child supervisor nor for a worker leaf.
    await expect(toggle(page, 'mock_dyn_sup_a')).toHaveCount(0);
    await expect(toggle(page, 'mock_static_worker')).toHaveCount(0);

    await expect(toggle(page, 'mock_dyn_sup_b')).toHaveAttribute(
      'data-collapsed',
      'true'
    );
    const dynSupB = await cyNode(page, 'mock_dyn_sup_b');
    expect(dynSupB.exists && dynSupB.label).toContain('(1)');
  });

  test('expanding a stub loads its children', async ({ page }) => {
    await clickToggle(page, 'mock_deep_sup_1');

    await expect(toggle(page, 'mock_deep_sup_2')).toHaveAttribute(
      'data-collapsed',
      'true'
    );
    const child = await cyNode(page, 'mock_deep_sup_2');
    expect(child).toMatchObject({ exists: true, hidden: false, childCount: 1 });
  });

  test('collapsing hides loaded descendants without a refetch', async ({
    page,
  }) => {
    await clickToggle(page, 'mock_deep_sup_1');
    await expect(toggle(page, 'mock_deep_sup_2')).toBeVisible();

    await clickToggle(page, 'mock_deep_sup_1');

    await expect(async () => {
      expect(await cyNode(page, 'mock_deep_sup_2')).toMatchObject({
        exists: true,
        hidden: true,
      });
    }).toPass();
    await expect(toggle(page, 'mock_deep_sup_2')).toBeHidden();
  });

  test('re-expanding reveals the previously collapsed subtree', async ({
    page,
  }) => {
    await clickToggle(page, 'mock_deep_sup_1');
    await expect(toggle(page, 'mock_deep_sup_2')).toBeVisible();
    await clickToggle(page, 'mock_deep_sup_1');
    await expect(toggle(page, 'mock_deep_sup_2')).toBeHidden();

    await clickToggle(page, 'mock_deep_sup_1');

    await expect(toggle(page, 'mock_deep_sup_2')).toBeVisible();
    expect(await cyNode(page, 'mock_deep_sup_2')).toMatchObject({
      exists: true,
      hidden: false,
      hiddenCount: 0,
    });
  });

  // Uses mock_root_sup (kept in every walk by the depth setting, so refetches
  // never prune its subtree) and the mock_app application node (not a real
  // pid, so its toggle is purely client-side). This makes the client-only
  // hidden_count bookkeeping observable without racing the auto-refresh.
  test('a node under two collapsed ancestors stays hidden until both expand', async ({
    page,
  }) => {
    await clickToggle(page, 'mock_root_sup'); // collapse inner
    await clickToggle(page, 'app:mock_app'); // collapse outer
    await clickToggle(page, 'app:mock_app'); // re-expand outer only

    await expect(async () => {
      await focusNode(page, 'mock_root_sup');
      await expect(toggle(page, 'mock_root_sup')).toHaveAttribute(
        'data-collapsed',
        'true',
        { timeout: 1_000 }
      );
    }).toPass();
    // Still hidden by the collapsed mock_root_sup.
    expect(await cyNode(page, 'mock_deep_sup_1')).toMatchObject({
      exists: true,
      hidden: true,
      hiddenCount: 1,
    });
  });

  test('collapsing an expanded node prunes its loaded children on refetch', async ({
    page,
  }) => {
    await clickToggle(page, 'mock_deep_sup_1');
    await expect(toggle(page, 'mock_deep_sup_2')).toBeVisible();
    await clickToggle(page, 'mock_deep_sup_2');
    await expect(toggle(page, 'mock_deep_sup_3')).toBeVisible();

    await clickToggle(page, 'mock_deep_sup_2'); // collapse inner
    await clickToggle(page, 'mock_deep_sup_1'); // collapse outer
    await clickToggle(page, 'mock_deep_sup_1'); // re-expand outer only

    // Re-expanding refetches; mock_deep_sup_2 is no longer expanded on the
    // server, so it returns as a collapsed stub and its subtree is removed.
    await expect(async () => {
      await focusNode(page, 'mock_deep_sup_2');
      await expect(toggle(page, 'mock_deep_sup_2')).toHaveAttribute(
        'data-collapsed',
        'true',
        { timeout: 1_000 }
      );
      expect(await cyNode(page, 'mock_deep_sup_3')).toEqual({ exists: false });
    }).toPass();
  });

  // A node that gains children at
  // runtime must recompute its collapsed state from the delta patch.
  test('a childless supervisor gaining a child gets a working + toggle', async ({
    page,
  }) => {
    await expect(toggle(page, 'mock_dyn_sup_a')).toHaveCount(0);

    rpcOk('mock_app_ctl add_child [mock_dyn_sup_a, tmp_a1]');

    await refreshed(page, async () => {
      await expect(toggle(page, 'mock_dyn_sup_a')).toHaveAttribute(
        'data-collapsed',
        'true',
        { timeout: 1_000 }
      );
    });
    const sup = await cyNode(page, 'mock_dyn_sup_a');
    expect(sup.exists && sup.label).toContain('(1)');

    await clickToggle(page, 'mock_dyn_sup_a');
    await expect(async () => {
      expect(await cyNode(page, 'tmp_a1')).toMatchObject({
        exists: true,
        hidden: false,
      });
    }).toPass();
  });

  // An already-expanded node gaining another child must
  // stay expanded instead of flipping back to +.
  test('an expanded supervisor gaining a child stays expanded', async ({
    page,
  }) => {
    await clickToggle(page, 'mock_dyn_sup_b');
    await expect(async () => {
      expect(await cyNode(page, 'mock_dyn_worker_b1')).toMatchObject({
        exists: true,
        hidden: false,
      });
    }).toPass();

    rpcOk('mock_app_ctl add_child [mock_dyn_sup_b, tmp_b2]');

    await refreshed(page, async () => {
      expect(await cyNode(page, 'tmp_b2')).toMatchObject({
        exists: true,
        hidden: false,
      });
    });
    await expect(toggle(page, 'mock_dyn_sup_b')).toHaveAttribute(
      'data-collapsed',
      'false'
    );
    const sup = await cyNode(page, 'mock_dyn_sup_b');
    expect(sup.exists && sup.label).toContain('(2)');
  });

  test('removing the last child drops the node and its toggle', async ({
    page,
  }) => {
    rpcOk('mock_app_ctl add_child [mock_dyn_sup_a, tmp_a1]');
    await refreshed(page, async () => {
      await expect(toggle(page, 'mock_dyn_sup_a')).toBeVisible({
        timeout: 1_000,
      });
    });
    await clickToggle(page, 'mock_dyn_sup_a');
    await expect(async () => {
      expect(await cyNode(page, 'tmp_a1')).toMatchObject({ exists: true });
    }).toPass();

    rpcOk('mock_app_ctl remove_child [mock_dyn_sup_a, tmp_a1]');

    await refreshed(page, async () => {
      expect(await cyNode(page, 'tmp_a1')).toEqual({ exists: false });
    });
    await expect(toggle(page, 'mock_dyn_sup_a')).toBeHidden();
  });

  test('changing depth resets manual expansion', async ({ page }) => {
    await clickToggle(page, 'mock_deep_sup_1');
    await expect(toggle(page, 'mock_deep_sup_2')).toBeVisible();
    await clickToggle(page, 'mock_deep_sup_2');
    await expect(toggle(page, 'mock_deep_sup_3')).toBeVisible();

    await page.locator('input[name="tree_controls[depth]"]').fill('4');

    // At depth 4 mock_deep_sup_2 is reached by the walk itself, but the manual
    // expansion of mock_deep_sup_2 is forgotten, so mock_deep_sup_3 is gone.
    await expect(async () => {
      expect(await cyNode(page, 'mock_deep_sup_3')).toEqual({ exists: false });
    }).toPass({ timeout: 1_000 });
    await expect(async () => {
      await focusNode(page, 'mock_deep_sup_2');
      await expect(toggle(page, 'mock_deep_sup_2')).toHaveAttribute(
        'data-collapsed',
        'true',
        { timeout: 1_000 }
      );
    }).toPass();
  });
});

// Regression coverage for PR #105 (floating nodes in the supervision tree).
// A relationship edge (here a monitor; link / monitored_by collapse the same
// way) can join two otherwise independent branches. Collapsing used to follow
// those relation edges as if they were part of the supervision spine, which —
// collapsing the two branches one at a time — produced two defects:
//
//   1. Collapsing one branch kept the relation *target* visible (correct) but
//      wrongly hid that target's own strict-supervision subtree in the other,
//      still-expanded branch — so after each collapse we assert the untouched
//      branch stays fully visible.
//   2. Once both joined branches were collapsed, a node was left "floating" —
//      still drawn but with every edge gone — instead of being hidden.
//
// The scenario runs across a matrix so every collapse path is covered:
//   * expansion — branches opened with the +/- toggle buttons, vs. opened
//     wholesale by raising the walk depth (a structurally different path: the
//     leaves are then discovered by the walk, not via the relation);
//   * order — collapse branch A first then B, vs. B first then A.
//
const BRANCH = {
  a: { top: 'mock_dyn_sup_a', sup: 'rel_sup_a', leaf: 'rel_leaf_a' },
  b: { top: 'mock_dyn_sup_b', sup: 'rel_sup_b', leaf: 'rel_leaf_b' },
} as const;

test.describe('SupervisionTreeLive › relation-edge collapse', () => {
  test.beforeAll(() => {
    rpcOk('mock_app_ctl reset []');
    // Two deep branches joined by a monitor between their leaves:
    rpcOk('mock_worker monitor_process [rel_leaf_a, rel_leaf_b]');
  });

  test.afterAll(() => {
    rpcOk('mock_worker clear_relations [rel_leaf_a]');
  });

  for (const expansion of ['toggle', 'depth'] as const) {
    for (const [first, second] of [
      ['a', 'b'],
      ['b', 'a'],
    ] as const) {
      test(`keeps the other branch and never floats a node (${expansion} expand, collapse ${first} then ${second})`, async ({
        page,
      }) => {
        await openTree(page);

        if (expansion === 'toggle') {
          // Open branch A first, then B, via the overlay toggle buttons.
          await clickToggle(page, BRANCH.a.top);
          await expect(toggle(page, BRANCH.a.sup)).toBeVisible();
          await clickToggle(page, BRANCH.a.sup);
          await clickToggle(page, BRANCH.b.top);
          await expect(toggle(page, BRANCH.b.sup)).toBeVisible();
          await clickToggle(page, BRANCH.b.sup);
        } else {
          // Depth 5 reaches the leaves (app → p → root_sup → dyn_sup →
          // rel_sup → rel_leaf), so both branches open structurally at once.
          await page.locator('input[name="tree_controls[depth]"]').fill('5');
        }

        await expect(async () => {
          expect(await cyNode(page, BRANCH.a.leaf)).toMatchObject({
            exists: true,
            hidden: false,
          });
          expect(await cyNode(page, BRANCH.b.leaf)).toMatchObject({
            exists: true,
            hidden: false,
          });
        }).toPass({ timeout: 5_000 });
        // Guard: the collapses below only exercise the fix if the relation edge
        // actually joins the two branches.
        expect(
          await relEdge(page, BRANCH.a.leaf, BRANCH.b.leaf, 'monitor')
        ).toBe(true);

        // Focusing re-zooms the node into view so its overlay toggle exists
        // (depth-expanded trees fit too small for the buttons to render).
        const collapse = async (key: 'a' | 'b') => {
          await focusNode(page, BRANCH[key].top);
          await page.waitForTimeout(300);
          await clickToggle(page, BRANCH[key].top);
        };

        // Collapse the first branch: its supervisor hides, while the other
        // branch — reachable only through the relation edge — must stay fully
        // visible (buggy builds over-collapse into it), and nothing floats.
        // (The first branch's own leaf is not asserted here: when it is the
        // relation-discovered endpoint it legitimately lingers, still tied to
        // its visible partner, until that partner is collapsed too, below.)
        await collapse(first);
        await expect(async () => {
          expect(await cyNode(page, BRANCH[first].sup)).toMatchObject({
            exists: true,
            hidden: true,
          });
          expect(await cyNode(page, BRANCH[second].sup)).toMatchObject({
            exists: true,
            hidden: false,
          });
          expect(await cyNode(page, BRANCH[second].leaf)).toMatchObject({
            exists: true,
            hidden: false,
          });
          expect(await floatingNodes(page)).toEqual([]);
        }).toPass({ timeout: 3_000 });

        // Collapse the second branch too: everything joined by the relation is
        // now hidden — nothing left floating (buggy builds strand a leaf here).
        await collapse(second);
        await expect(async () => {
          expect(await cyNode(page, BRANCH[first].leaf)).toMatchObject({
            exists: true,
            hidden: true,
          });
          expect(await cyNode(page, BRANCH[second].leaf)).toMatchObject({
            exists: true,
            hidden: true,
          });
          expect(await floatingNodes(page)).toEqual([]);
        }).toPass({ timeout: 3_000 });
      });
    }
  }
});

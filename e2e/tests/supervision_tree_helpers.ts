import cytoscape, { EdgeSingular } from 'cytoscape';
import { execSync } from 'node:child_process';
import { expect, type Page } from '@playwright/test';
import { NODE_NAME, COOKIE, sel, ensureConnected } from './fixtures';

/**
 * Runs `mock_app_ctl` (or any MFA) on the target node and returns the printed
 * result term, e.g. rpc('mock_app_ctl add_child [mock_dyn_sup_a, tmp_a1]').
 */
export function rpc(mfa: string): string {
  return execSync(`erl_call -name ${NODE_NAME} -c ${COOKIE} -a '${mfa}'`, {
    encoding: 'utf8',
  }).trim();
}

export function rpcOk(mfa: string) {
  expect(rpc(mfa)).toBe('ok');
}

/**
 * The floating +/- overlay button of a graph node, addressed by its registered
 * name or by its key (e.g. 'app:mock_app' for application nodes, whose name
 * resolves to the unregistered application master's pid).
 */
export function toggle(page: Page, ref: string) {
  return page.locator(
    `.cy-toggle[data-name="${ref}"], .cy-toggle[data-key="${ref}"]`
  );
}

type CyNodeSnapshot =
  | { exists: false }
  | {
      exists: true;
      hidden: boolean;
      isCollapsed: boolean;
      childCount: number;
      hiddenCount: number;
      label: string;
    };

/**
 * Snapshot of a graph node's state, read from the cytoscape instance the hook
 * exposes on #supervision-tree-body. Nodes are canvas-drawn, so this is the
 * only way to assert on ones that have no overlay button (workers, hidden).
 */
export function cyNode(page: Page, ref: string): Promise<CyNodeSnapshot> {
  return page.evaluate((ref) => {
    const cy = (document.getElementById('supervision-tree-body') as any)
      ?._cy as cytoscape.Core;
    if (!cy) return { exists: false as const };

    const hit = cy
      .nodes()
      .filter((x) => x.id() === ref || String(x.data('name')) === ref);

    return hit.length
      ? {
          exists: true as const,
          hidden: hit[0].hasClass('hidden'),
          isCollapsed: !!hit[0].data('is_collapsed'),
          childCount: hit[0].data('child_count') as number,
          hiddenCount: (hit[0].data('hidden_count') ?? 0) as number,
          label: String(hit[0].data('displayLabel')),
        }
      : { exists: false as const };
  }, ref);
}

/**
 * Whether a relationship edge (link / monitor / monitored_by) of the given kind
 * connects the two named nodes, in either direction. Relationship edges are
 * keyed by pid, so this resolves the endpoints by their registered name first.
 */
export function relEdge(
  page: Page,
  fromRef: string,
  toRef: string,
  kind: string
): Promise<boolean> {
  return page.evaluate(
    ({ fromRef, toRef, kind }) => {
      const cy = (document.getElementById('supervision-tree-body') as any)
        ?._cy as cytoscape.Core;
      if (!cy) return false;

      const idOf = (ref: string) => {
        const hit = cy
          .nodes()
          .filter((x) => x.id() === ref || String(x.data('name')) === ref);
        return hit.length ? hit[0].id() : null;
      };

      const a = idOf(fromRef);
      const b = idOf(toRef);

      if (!a || !b) return false;

      return cy.edges().some((e) => {
        const s = (e as EdgeSingular).source().id();
        const t = (e as EdgeSingular).target().id();
        return (
          e.data('kind') === kind &&
          ((s === a && t === b) || (s === b && t === a))
        );
      });
    },
    { fromRef, toRef, kind }
  );
}

/**
 * Names of nodes that are "floating": visible in the graph yet have no visible
 * neighbour (every connected node is hidden). This is the exact symptom the
 * relation-edge collapse fix targets — a node left stranded with no edges.
 */
export function floatingNodes(page: Page): Promise<string[]> {
  return page.evaluate(() => {
    const cy = (document.getElementById('supervision-tree-body') as any)
      ?._cy as cytoscape.Core;
    if (!cy) return [];

    const out: string[] = [];

    cy.nodes().forEach((n) => {
      if (n.hasClass('hidden')) return;
      const visibleNeighbors = n
        .connectedEdges()
        .connectedNodes()
        .filter((m) => m.id() !== n.id() && !m.hasClass('hidden')).length;
      if (visibleNeighbors === 0) out.push(String(n.data('name')));
    });

    return out;
  });
}

/**
 * Opens the supervision tree page, selects mock_app and waits until the graph
 * has rendered and overlay buttons are in place.
 */
export async function openTree(page: Page) {
  await ensureConnected(page);
  await page.goto(`/node/${NODE_NAME}/supervision-tree`);
  await page
    .locator('input[name="tree_controls[apps][]"][value="mock_app"]')
    .check();
  await expect(page.locator(sel.stStatus)).toHaveText('ok', {
    timeout: 1_000,
  });
  await expect(page.locator(sel.stBody)).toBeVisible();
  await expect(toggle(page, 'mock_deep_sup_1')).toBeVisible();
}

/**
 * Centers the graph viewport on a node at a zoom high enough for overlay
 * buttons to exist (the hook only renders them at zoom >= 0.45 for nodes
 * inside the viewport). Returns false if the node isn't (visibly) in the graph.
 */
export function focusNode(page: Page, ref: string): Promise<boolean> {
  return page.evaluate((ref) => {
    const cy = (document.getElementById('supervision-tree-body') as any)
      ?._cy as cytoscape.Core;
    if (!cy) return false;

    const node = cy
      .nodes()
      .filter((x) => x.id() === ref || String(x.data('name')) === ref);

    if (!node.length || node.hasClass('hidden')) return false;
    if (cy.zoom() < 0.6) cy.zoom(0.6);
    cy.center(node);
    return true;
  }, ref);
}

/**
 * Clicks a node's overlay toggle and waits for its collapsed state to flip.
 * Two sources of silent no-ops are handled: during layout animations the hook
 * swallows clicks (disabledClick), and overlay buttons only exist while their
 * node is in view at sufficient zoom — a layout after a previous toggle can
 * break either, so we re-focus the node when its button is missing.
 */
export async function clickToggle(page: Page, ref: string) {
  expect(await focusNode(page, ref)).toBe(true);

  const btn = toggle(page, ref);
  const before = await btn.getAttribute('data-collapsed', { timeout: 2_000 });
  const after = before === 'true' ? 'false' : 'true';

  await expect(async () => {
    if (!(await btn.isVisible())) {
      expect(await focusNode(page, ref)).toBe(true);
    }
    if (
      (await btn.getAttribute('data-collapsed', { timeout: 1_000 })) !== after
    ) {
      await btn.click();
    }
    await expect(btn).toHaveAttribute('data-collapsed', after, {
      timeout: 1_000,
    });
  }).toPass({ timeout: 4_000 });
}

/**
 * Nudges a refresh, then polls the given assertion. Never assert on the
 * loading->ok status transition itself: it races the 5 s auto-refresh and the
 * refresh button's 1 s phx-throttle. The auto-refresh guarantees the new tree
 * arrives within ~6 s even if the button click was throttled away.
 */
export async function refreshed(page: Page, assertion: () => Promise<void>) {
  await page.locator(sel.stRefresh).click();
  await expect(assertion).toPass({ timeout: 2_000 });
}

/**
 * Selects a graph node by emitting cytoscape's `onetap` (the event the
 * SupervisionTree hook listens for). Avoids flaky canvas hit-testing.
 */
export async function selectNode(page: Page, ref: string) {
  const ok = await page.evaluate((n) => {
    const cy = (document.getElementById('supervision-tree-body') as any)
      ?._cy as cytoscape.Core;
    if (!cy) return false;
    const hit = cy
      .nodes()
      .filter((x) => x.id() === n || String(x.data('name')) === n);
    if (!hit.length || hit.hasClass('hidden')) return false;
    hit[0].emit('onetap');
    return true;
  }, ref);
  expect(ok).toBe(true);
}

/**
 * Clears the current selection by emitting a background `tap` on the cytoscape core
 */
export async function clearSelection(page: Page) {
  const ok = await page.evaluate(() => {
    const cy = (document.getElementById('supervision-tree-body') as any)
      ?._cy as cytoscape.Core;
    if (!cy) return false;
    cy.emit('tap');
    return true;
  });
  expect(ok).toBe(true);
}

/** CSS `--details-panel-width` in px (what DetailsPanelResize writes). */
export function detailsPanelCssWidth(page: Page): Promise<number> {
  return page
    .locator('#details-panel')
    .evaluate((el) =>
      Number.parseFloat(
        getComputedStyle(el).getPropertyValue('--details-panel-width')
      )
    );
}

/**
 * Drags the details panel resize handle left by `deltaPx` (grows the panel).
 * Uses PointerEvents so the hook's document-level move listeners fire reliably.
 */
export async function resizeDetailsPanel(page: Page, deltaPx: number) {
  await page.evaluate((delta) => {
    const handle = document.getElementById('details-panel-resize-handle');
    if (!handle) throw new Error('resize handle missing');

    const rect = handle.getBoundingClientRect();
    const startX = rect.left + rect.width / 2;
    const y = rect.top + rect.height / 2;

    const fire = (target: EventTarget, type: string, clientX: number) => {
      target.dispatchEvent(
        new PointerEvent(type, {
          bubbles: true,
          cancelable: true,
          clientX,
          clientY: y,
          button: 0,
          buttons: type === 'pointerup' || type === 'pointercancel' ? 0 : 1,
          pointerId: 1,
          pointerType: 'mouse',
          isPrimary: true,
        })
      );
    };

    fire(handle, 'pointerdown', startX);
    fire(document, 'pointermove', startX - delta);
    fire(document, 'pointerup', startX - delta);
  }, deltaPx);
}

import { test, expect } from '@playwright/test';
import {
  openTree,
  selectNode,
  clearSelection,
  detailsPanelCssWidth,
  resizeDetailsPanel,
} from './supervision_tree_helpers';

test.describe('SupervisionTreeLive › DetailsPanel', () => {
  test.beforeEach(async ({ page }) => {
    await page.addInitScript(() => {
      localStorage.removeItem('voyager:details-panel-width');
    });
    await openTree(page);
  });

  test('selecting a node via cytoscape emit opens the details panel', async ({
    page,
  }) => {
    const panel = page.locator('#details-panel');

    await expect(panel).toHaveClass(/translate-x-full/);

    await selectNode(page, 'mock_root_sup');

    await expect(panel).toHaveClass(/translate-x-0/);
    await expect(panel).toContainText('Supervisor');
    await expect(panel).toContainText('mock_root_sup');
  });

  test('resizing the panel updates its width', async ({ page }) => {
    await selectNode(page, 'mock_root_sup');

    const panel = page.locator('#details-panel');
    await expect(panel).toHaveClass(/translate-x-0/);
    await expect(page.locator('#details-panel-resize-handle')).toBeVisible();

    const before = await detailsPanelCssWidth(page);
    await resizeDetailsPanel(page, 100);

    await expect(async () => {
      const after = await detailsPanelCssWidth(page);
      expect(after).toBeGreaterThan(before + 40);
    }).toPass();

    const stored = await page.evaluate(() =>
      localStorage.getItem('voyager:details-panel-width')
    );
    expect(Number.parseFloat(stored ?? '')).toBeGreaterThan(before + 40);
  });

  test('emitting select-node with empty key closes the details panel', async ({
    page,
  }) => {
    await selectNode(page, 'mock_root_sup');

    const panel = page.locator('#details-panel');
    await expect(panel).toHaveClass(/translate-x-0/);

    await clearSelection(page);

    await expect(panel).toHaveClass(/translate-x-full/);
  });

  test('clicking a pid link selects that process in the details panel', async ({
    page,
  }) => {
    await selectNode(page, 'mock_root_sup');

    const panel = page.locator('#details-panel');
    await expect(panel).toHaveClass(/translate-x-0/);

    const chip = panel.locator('button[id^="details-panel-link-"]').first();
    await expect(chip).toBeEnabled();

    const label = (await chip.innerText()).trim();
    await chip.click();

    await expect(panel).toHaveClass(/translate-x-0/);
    await expect(panel.locator('#details-panel-pid')).toHaveText(label);
    await expect(page.locator('#details-panel-back')).toBeVisible();

    await page.locator('#details-panel-back').click();

    await expect(panel).toContainText('mock_root_sup');
    await expect(page.locator('#details-panel-back')).toHaveCount(0);
  });
});

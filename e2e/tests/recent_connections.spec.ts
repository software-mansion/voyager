import { test, expect } from '@playwright/test';
import { NODE_NAME, sel } from './fixtures';

test.describe('ConnectLive › recent connections', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
  });

  test('shows connected node in recent connections', async ({ page }) => {
    await expect(page.locator(sel.recentConnections)).toBeVisible();
    await expect(page.locator(sel.recentConnections)).toContainText(NODE_NAME);
  });

  test('fills the form from a recent connection row', async ({ page }) => {
    await page
      .locator(`${sel.recentConnections} button[phx-click="fill_recent"]`)
      .first()
      .click();
    await expect(page.locator(sel.nodeNameInput)).toHaveValue(NODE_NAME);
  });
});

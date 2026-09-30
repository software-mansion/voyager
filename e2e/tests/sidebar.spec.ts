import { test, expect } from '@playwright/test';
import { NODE_NAME, ensureConnected } from './fixtures';

const sidebar = '#app-sidebar';

test.describe('Sidebar', () => {
  test.beforeEach(async ({ page }) => {
    await ensureConnected(page);
    await page.goto(`/node/${NODE_NAME}`);
    await expect(page.locator(sidebar)).toBeVisible();
  });

  test('Cmd/Ctrl+B toggles the sidebar width', async ({ page }) => {
    await page.keyboard.press('ControlOrMeta+b');
    await expect(page).toHaveURL(/sidebar=compact/);
    await expect(page.locator(sidebar)).toHaveClass(/mode-compact/);

    await page.keyboard.press('ControlOrMeta+b');
    await expect(page).toHaveURL(/sidebar=full/);
    await expect(page.locator(sidebar)).toHaveClass(/mode-full/);
  });
});

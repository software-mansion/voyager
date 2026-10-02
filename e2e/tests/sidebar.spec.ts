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
    await expect(page.locator(sidebar)).toHaveClass(/mode-compact/);

    await page.keyboard.press('ControlOrMeta+b');
    await expect(page.locator(sidebar)).toHaveClass(/mode-full/);
    await expect(page).not.toHaveURL(/sidebar=/);
  });

  test('the chosen width survives navigation and reload', async ({ page }) => {
    await page.keyboard.press('ControlOrMeta+b');
    await expect(page.locator(sidebar)).toHaveClass(/mode-compact/);

    await page.locator('#sidebar-nav-processes').click();
    await expect(page).toHaveURL(new RegExp(`/node/${NODE_NAME}/processes$`));
    await expect(page.locator(sidebar)).toHaveClass(/mode-compact/);

    await page.reload();
    await expect(page.locator(sidebar)).toHaveClass(/mode-compact/);
  });
});

import { test, expect } from '@playwright/test';
import { NODE_NAME, ensureConnected } from './fixtures';

const sidebar = '#app-sidebar';

test.describe('Sidebar', () => {
  test.beforeEach(async ({ page }) => {
    await ensureConnected(page);
    await page.goto(`/node/${NODE_NAME}`);
    await expect(page.locator(sidebar)).toBeVisible();
  });

  test('Cmd/Ctrl+B toggles the sidebar width and remembers it', async ({
    page,
  }) => {
    const html = page.locator('html');

    await page.keyboard.press('ControlOrMeta+b');
    await expect(html).toHaveAttribute('data-sidebar', 'compact');

    await page.locator('#sidebar-nav-processes').click();
    await expect(page).toHaveURL(/\/processes/);
    await expect(html).toHaveAttribute('data-sidebar', 'compact');

    await page.reload();
    await expect(html).toHaveAttribute('data-sidebar', 'compact');

    await page.keyboard.press('ControlOrMeta+b');
    await expect(html).toHaveAttribute('data-sidebar', 'full');
  });
});

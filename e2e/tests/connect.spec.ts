import { test, expect } from '@playwright/test';
import { NODE_NAME, COOKIE, sel } from './fixtures';

test('connects to node and navigates to node page', async ({ page }) => {
  await page.goto('/');
  await page.locator(sel.nodeNameInput).fill(NODE_NAME);
  await page.locator(sel.cookieInput).fill(COOKIE);
  await page.locator(sel.connectBtn).click();
  await expect(page).toHaveURL(/\/node\//);
});

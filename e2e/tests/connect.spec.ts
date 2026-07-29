import { test, expect } from '@playwright/test';
import {
  NODE_NAME,
  COOKIE,
  sel,
  ensureDisconnected,
  fillConnectForm,
} from './fixtures';

test('connects to node and navigates to node page', async ({ page }) => {
  await ensureDisconnected(page);
  await fillConnectForm(page, NODE_NAME, COOKIE);
  await page.locator(sel.connectBtn).click();
  await expect(page).toHaveURL(/\/node\//);
});

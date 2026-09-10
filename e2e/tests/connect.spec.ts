import { test, expect } from '@playwright/test';
import {
  NODE_NAME,
  NODE_NAME_V6,
  COOKIE,
  sel,
  ensureDisconnected,
  fillConnectForm,
} from './fixtures';

test.describe.serial('direct connect', () => {
  test('connects to an IPv6 node and disconnects', async ({ page }) => {
    await ensureDisconnected(page);
    await fillConnectForm(page, NODE_NAME_V6, COOKIE);
    await page.locator(sel.connectBtn).click();
    await expect(page).toHaveURL(/\/node\//);
    await ensureDisconnected(page);
  });

  test('connects to node and navigates to node page', async ({ page }) => {
    await ensureDisconnected(page);
    await fillConnectForm(page, NODE_NAME, COOKIE);
    await page.locator(sel.connectBtn).click();
    await expect(page).toHaveURL(/\/node\//);
  });
});

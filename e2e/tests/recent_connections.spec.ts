import { test, expect } from '@playwright/test';
import {
  NODE_NAME,
  sel,
  fillRecentBtn,
  ensureConnected,
} from './fixtures';

test.describe.configure({ mode: 'serial' });

test.describe('ConnectLive › recent connections', () => {
  test.afterAll(async ({ browser }) => {
    const page = await browser.newPage();
    await ensureConnected(page);
    await page.close();
  });

  test('shows recent connection and disables fill while connected', async ({
    page,
  }) => {
    await page.goto('/');

    await expect(page.locator(sel.recentConnections)).toBeVisible();
    await expect(page.locator(sel.recentConnections)).toContainText(NODE_NAME);
    await expect(page.locator(sel.disconnectFromConnect)).toBeVisible();
    await expect(page.locator(sel.connectBtn)).toBeDisabled();
    await expect(fillRecentBtn(page).first()).toBeDisabled();
  });

  test('disconnects from the connect page and re-enables the form', async ({
    page,
  }) => {
    await page.goto('/');
    await page.locator(sel.disconnectFromConnect).click();

    await expect(page.locator(sel.disconnectFromConnect)).toBeHidden();
    await expect(page.locator(sel.connectBtn)).toBeEnabled();
    await expect(fillRecentBtn(page).first()).toBeEnabled();
  });

  test('fills the form from a recent connection row', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator(sel.connectBtn)).toBeEnabled();

    await fillRecentBtn(page).first().click();
    await expect(page.locator(sel.nodeNameInput)).toHaveValue(NODE_NAME);
  });
});

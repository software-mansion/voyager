import { test, expect } from '@playwright/test';
import {
  NODE_NAME,
  sel,
  ensureDisconnected,
  fillConnectForm,
} from './fixtures';

test.describe('ConnectLive › form validation', () => {
  test.beforeEach(async ({ page }) => {
    await ensureDisconnected(page);
  });

  test('renders the connection form', async ({ page }) => {
    await expect(page.locator(sel.connectForm)).toBeVisible();
    await expect(page.locator(sel.nodeNameInput)).toBeVisible();
    await expect(page.locator(sel.cookieInput)).toBeVisible();
    await expect(page.locator(sel.connectBtn)).toBeVisible();
  });

  test('shows required field errors on empty submission', async ({ page }) => {
    await page.locator(sel.connectBtn).click();
    await expect(page.locator(sel.connectForm)).toContainText("can't be blank");
  });

  test('shows format validation error for invalid node name', async ({
    page,
  }) => {
    await fillConnectForm(page, 'invalid', 'somecookie');
    await page.locator(sel.connectBtn).click();
    await expect(page.locator(sel.connectForm)).toContainText(
      'name@host format'
    );
  });

  test('shows authentication error for wrong cookie', async ({ page }) => {
    await fillConnectForm(page, NODE_NAME, 'wrong_cookie');
    await page.locator(sel.connectBtn).click();
    await expect(page.locator(sel.connectForm)).toContainText(
      'Authentication failed'
    );
  });
});

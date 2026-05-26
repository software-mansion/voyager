import { test, expect } from '@playwright/test';
import { NODE_NAME } from './fixtures';

const nodeUrl = `/node/${NODE_NAME}`;

test.describe('NodeInfoLive', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(nodeUrl);
  });

  test('shows the connected node name as the page heading', async ({
    page,
  }) => {
    await expect(page.locator('h1')).toContainText(NODE_NAME);
  });

  test('shows the OTP release info card', async ({ page }) => {
    const otpCard = page.locator('.card-body', { hasText: 'OTP' });
    await expect(otpCard).toBeVisible();
    await expect(otpCard).not.toContainText('—');
  });
});

import { test, expect } from '@playwright/test';
import { execSync } from 'node:child_process';
import { NODE_NAME, sel } from './fixtures';

const nodeUrl = `/node/${NODE_NAME}`;

function expectedOtpRelease(): string {
  return execSync(
    'erl -noshell -eval "io:format(\\"~s\\", [erlang:system_info(otp_release)]), halt()."',
    { encoding: 'utf8' }
  ).trim();
}

test.describe('NodeInfoLive', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(nodeUrl);
    await expect(page.locator(sel.nodeInfoLoading)).toBeHidden();
    await expect(page.locator(sel.nodeInfoContent)).toBeVisible();
  });

  test('shows the connected node name and OTP', async ({ page }) => {
    await expect(page.locator('h1')).toContainText(NODE_NAME);

    const runtimeCard = page.locator(sel.nodeInfoContent).locator('.card', {
      has: page.getByRole('heading', { name: 'Runtime' }),
    });

    const otpRelease = runtimeCard
      .getByText('OTP', { exact: true })
      .locator('..')
      .locator('> div')
      .nth(1);

    await expect(otpRelease).toHaveText(expectedOtpRelease());
  });
});

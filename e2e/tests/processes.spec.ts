import { test, expect, type Page } from '@playwright/test';
import { NODE_NAME, ensureConnected, waitForLiveView } from './fixtures';

const processesUrl = `/node/${NODE_NAME}/processes`;

const sel = {
  pidLinks: '#processes-table tbody tr[id] td[data-column="pid"] a',
  openSettings: '#open-settings',
  back: 'a[title="Back"]',
};

async function setPidFormat(page: Page, format: 'distribution' | 'local') {
  const button = page.locator(`#pid-format-${format}`);
  await button.click();
  await expect(button).toHaveAttribute('aria-pressed', 'true');
}

async function expectPids(page: Page, format: RegExp) {
  const links = page.locator(sel.pidLinks);
  await expect(links.first()).toBeVisible();

  await expect(async () => {
    const pids = (await links.allTextContents()).map((text) => text.trim());
    expect(pids.length).toBeGreaterThan(0);
    for (const pid of pids) expect(pid).toMatch(format);
  }).toPass();
}

// The pid format is a global setting, so this spec runs after the others.
test.describe('ProcessesLive › pid format', () => {
  test.beforeEach(async ({ page }) => {
    await ensureConnected(page);
  });

  test.afterEach(async ({ page }) => {
    await page.goto('/settings');
    await waitForLiveView(page);
    await setPidFormat(page, 'distribution');
  });

  test('switches the PID column from distribution to local form', async ({
    page,
  }) => {
    await page.goto('/settings');
    await waitForLiveView(page);
    await setPidFormat(page, 'distribution');

    await page.goto(processesUrl);
    await waitForLiveView(page);
    await expectPids(page, /^<[1-9]\d*\.\d+\.\d+>$/);

    await page.locator(sel.openSettings).click();
    await waitForLiveView(page);
    await setPidFormat(page, 'local');

    await page.locator(sel.back).click();
    await waitForLiveView(page);
    await expect(page).toHaveURL(/\/processes/);
    await expectPids(page, /^<0\.\d+\.\d+>$/);
  });
});

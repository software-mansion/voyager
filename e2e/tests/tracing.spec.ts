import { test, expect } from '@playwright/test';
import { NODE_NAME, ensureConnected, waitForLiveView } from './fixtures';
import { rpc, rpcOk } from './supervision_tree_helpers';

const sel = {
  stop: '#session-stop',
  resume: '#session-resume',
  rows: '#session-log-rows tr[id^="entry-"]',
  liveBadge: '#session-log .badge-success',
  indicator: '#tracing-indicator',
};

test.describe('TracingSessionLive', () => {
  test.beforeEach(async ({ page }) => {
    await ensureConnected(page);
  });

  test.afterEach(() => {
    rpcOk('mock_app_ctl trace_close []');
  });

  test('opens a running session and streams its rows', async ({ page }) => {
    const id = rpc('mock_app_ctl trace_session [false]');
    const sessionUrl = `/node/${NODE_NAME}/tracing/${id}`;

    await page.goto(sessionUrl);
    await waitForLiveView(page);

    await expect(page.locator(sel.stop)).toBeVisible();
    await expect(page.locator(sel.liveBadge)).toBeVisible();
    await expect(page.locator(sel.indicator)).toHaveAttribute(
      'href',
      sessionUrl
    );

    const rows = page.locator(sel.rows);
    await expect(async () => {
      expect(await rows.count()).toBeGreaterThan(4);
    }).toPass();

    const shown = await rows.count();
    await expect(async () => {
      expect(await rows.count()).toBeGreaterThan(shown);
    }).toPass();

    await page.locator(sel.stop).click();
    await expect(page.locator(sel.resume)).toBeVisible();
    await expect(page.locator(sel.liveBadge)).toBeHidden();
  });
});

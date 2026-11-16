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
    const sessionUrl = `/node/${encodeURIComponent(NODE_NAME)}/tracing/${id}`;

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

  test('aligns a row tooltip to the call / result column', async ({ page }) => {
    const id = rpc('mock_app_ctl trace_session [false]');
    await page.goto(`/node/${encodeURIComponent(NODE_NAME)}/tracing/${id}`);
    await waitForLiveView(page);

    const term = page.locator(`${sel.rows} [id$="-term"]`).first();
    await expect(term).toBeVisible();
    await page.locator(sel.stop).click();
    await expect(page.locator(sel.resume)).toBeVisible();

    await term.hover();
    const tip = page.locator('#log-term-tip');
    await expect(tip).toHaveClass(/is-open/);

    const column = await term.locator('xpath=ancestor::td').boundingBox();
    const tipBox = await tip.boundingBox();
    expect(tipBox!.x).toBeCloseTo(column!.x, 0);
  });

  test('marks a search match in a shown row’s tooltip', async ({ page }) => {
    const id = rpc('mock_app_ctl trace_session [false]');
    await page.goto(`/node/${encodeURIComponent(NODE_NAME)}/tracing/${id}`);
    await waitForLiveView(page);

    const terms = page.locator(`${sel.rows} [id$="-term"]`);
    await expect(async () => {
      expect(await terms.count()).toBeGreaterThan(2);
    }).toPass();
    await page.locator(sel.stop).click();
    await expect(page.locator(sel.resume)).toBeVisible();

    await page.locator('#log-search').fill('lookup');
    await expect(page.locator('#log-footer')).toContainText('matches in');
    await terms.first().hover();

    await expect(page.locator('#log-term-tip mark').first()).toHaveText(
      'lookup'
    );
  });
});

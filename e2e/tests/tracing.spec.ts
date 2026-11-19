import { test, expect } from '@playwright/test';
import { NODE_NAME, ensureConnected, waitForLiveView } from './fixtures';
import { rpc, rpcOk } from './supervision_tree_helpers';

const sel = {
  stop: '#session-stop',
  confirmStop: '#stop-session-modal-confirm',
  resume: '#session-resume',
  rows: '#session-log-rows tr[id^="entry-"]',
  liveBadge: '#session-log .badge-success',
  indicator: '#tracing-indicator',
  search: '#log-search',
  setParameters: '#session-set-parameters',
  configModal: '#config-modal',
  configModule: '#config_module',
  configFunction: '#config_function',
  configArity: '#config_arity',
  configStart: '#config-start',
};

test.describe('TracingSessionLive', () => {
  // The Tracer holds one active session, so parallel tests replace each other's.
  test.describe.configure({ mode: 'default' });

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
    await page.locator(sel.confirmStop).click();
    await expect(page.locator(sel.resume)).toBeVisible();
    await expect(page.locator(sel.liveBadge)).toBeHidden();
  });

  test('configures and starts a session from the parameters modal', async ({
    page,
  }) => {
    const id = rpc('mock_app_ctl trace_create []');
    await page.goto(`/node/${encodeURIComponent(NODE_NAME)}/tracing/${id}`);
    await waitForLiveView(page);

    await page.locator(sel.setParameters).click();
    const fields = [
      [sel.configModule, 'mock_tracee'],
      [sel.configFunction, 'lookup'],
      [sel.configArity, '1'],
    ];
    await expect(async () => {
      for (const [field, value] of fields) {
        await page.locator(field).fill(value, { timeout: 500 });
        await expect(page.locator(field)).toHaveValue(value, { timeout: 500 });
      }
    }).toPass({ timeout: 2000 });
    await page.locator(sel.configStart).click();

    await expect(page.locator(sel.configModal)).toBeHidden();
    await expect(page.locator(sel.stop)).toBeVisible();
  });

  test('aligns a row tooltip to the call / result column', async ({ page }) => {
    const id = rpc('mock_app_ctl trace_session [false]');
    await page.goto(`/node/${encodeURIComponent(NODE_NAME)}/tracing/${id}`);
    await waitForLiveView(page);

    const term = page.locator(`${sel.rows} [id$="-term"]`).first();
    await expect(term).toBeVisible();
    await page.locator(sel.stop).click();
    await page.locator(sel.confirmStop).click();
    await expect(page.locator(sel.resume)).toBeVisible();
    // The stop row lands in a later log flush and shifts the rows under the pointer.
    await expect(page.locator(sel.rows, { hasText: 'Stopped' })).toBeVisible();

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
    await page.locator(sel.confirmStop).click();
    await expect(page.locator(sel.resume)).toBeVisible();

    await page.locator(sel.search).fill('lookup');
    await expect(page.locator('#log-footer')).toContainText('matches in');
    await terms.first().hover();

    await expect(page.locator('#log-term-tip mark').first()).toHaveText(
      'lookup'
    );
  });

  test('focuses the search on / and keeps a / typed into it', async ({
    page,
  }) => {
    const id = rpc('mock_app_ctl trace_session [false]');
    await page.goto(`/node/${encodeURIComponent(NODE_NAME)}/tracing/${id}`);
    await waitForLiveView(page);
    await expect(page.locator(sel.rows).first()).toBeVisible();
    await expect(page.locator(sel.search)).toBeEnabled();

    await page.keyboard.press('/');
    await expect(page.locator(sel.search)).toBeFocused();

    await page.keyboard.press('/');
    await expect(page.locator(sel.search)).toHaveValue('/');
  });
});

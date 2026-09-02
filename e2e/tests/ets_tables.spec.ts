import { test, expect, type Page } from '@playwright/test';
import { NODE_NAME, ensureConnected, waitForLiveView } from './fixtures';

// Tables owned by mock_ets_owner on the target node (see e2e/mock_app).
const CACHE = ':mock_ets_cache';
const EVENTS = ':mock_ets_events';
const SECRETS = ':mock_ets_secrets';
const UNNAMED = ':mock_ets_unnamed';

const listUrl = `/node/${NODE_NAME}/ets-tables`;

const sel = {
  table: '#ets-tables-table',
  rows: '#ets-tables-table tbody tr[id]',
  summary: '#ets-tables-summary',
  search: '#controls_search',
  columnsPicker: '#ets-table-controls-columns',
  panelName: '#ets-table-details-name',
  panelShowMore: '#ets-table-details-show-more',
  panelNotFound: '#ets-table-details-not-found',
  details: '#ets-table-details',
  detailsError: '#ets-table-details-error',
  detailsPrivateBadge: '#ets-table-details-private-badge',
  detailsPeek: '#ets-table-details-peek',
  backToList: '#back-to-ets-tables',
};

function row(page: Page, name: string) {
  return page
    .locator(sel.rows)
    .filter({ has: page.locator('td[data-column="name"]', { hasText: name }) });
}

/** Narrows the list to the four mock_ets_* tables the mock app owns. */
async function filterToMockTables(page: Page) {
  await page.locator(sel.search).fill('mock_ets');
  await expect(page.locator(sel.rows)).toHaveCount(4);
}

test.describe('EtsTablesLive', () => {
  test.beforeEach(async ({ page }) => {
    await ensureConnected(page);
    await page.goto(listUrl);
    await waitForLiveView(page);
    await expect(page.locator(sel.rows).first()).toBeVisible();
  });

  test('lists the node tables with a fetch summary', async ({ page }) => {
    await expect(page.locator(sel.summary)).toContainText(
      /Fetched \d+\s+tables/
    );
    await expect(page.locator(sel.summary)).toContainText('in total');

    // System tables of any BEAM node, fetched for real over :erpc.
    await filterToMockTables(page);
    await page.locator(sel.search).fill('ac_tab');
    await expect(row(page, ':ac_tab')).toHaveCount(1);
  });

  test('search narrows the rows and the summary reports it', async ({
    page,
  }) => {
    await filterToMockTables(page);

    await expect(page.locator(sel.summary)).toContainText(/Showing 4\s+of \d+/);
    await expect(row(page, CACHE)).toBeVisible();
    await expect(row(page, EVENTS)).toBeVisible();
    await expect(row(page, SECRETS)).toBeVisible();
    await expect(row(page, UNNAMED)).toBeVisible();

    // The metadata the mock app created the tables with.
    await expect(row(page, CACHE)).toContainText('public');
    await expect(row(page, CACHE)).toContainText('set');
    await expect(row(page, CACHE)).toContainText('100');
    await expect(row(page, EVENTS)).toContainText('duplicate_bag');
    await expect(row(page, SECRETS)).toContainText('private');
    await expect(row(page, UNNAMED)).toContainText('#Ref');
  });

  test('sorts by a clicked column locally', async ({ page }) => {
    await filterToMockTables(page);

    await page.locator('button[phx-value-key="name"]').click();
    await expect(page.locator('th[data-column="name"]')).toHaveAttribute(
      'aria-sort',
      'ascending'
    );

    const names = page.locator(`${sel.rows} td[data-column="name"]`);
    await expect(names.first()).toContainText(CACHE);
    await expect(names.last()).toContainText(UNNAMED);

    await page.locator('button[phx-value-key="name"]').click();
    await expect(page.locator('th[data-column="name"]')).toHaveAttribute(
      'aria-sort',
      'descending'
    );
    await expect(names.first()).toContainText(UNNAMED);
  });

  test('the columns picker hides and reveals optional columns', async ({
    page,
  }) => {
    await expect(page.locator('th[data-column="type"]')).toBeVisible();
    await expect(page.locator('th[data-column="heir"]')).toHaveCount(0);

    await page.locator(sel.columnsPicker).click();
    await page.locator('#ets-table-controls-columns-type-input').uncheck();
    await page.locator('#ets-table-controls-columns-heir-input').check();

    await expect(page.locator('th[data-column="type"]')).toHaveCount(0);
    await expect(page.locator('th[data-column="heir"]')).toBeVisible();
    // Table and Memory are locked and stay.
    await expect(page.locator('th[data-column="name"]')).toBeVisible();
    await expect(page.locator('th[data-column="memory"]')).toBeVisible();
  });

  test('selecting a table opens the side panel and Show More its details page', async ({
    page,
  }) => {
    await filterToMockTables(page);

    await row(page, CACHE).locator('td[data-column="name"] a').click();
    await expect(page.locator(sel.panelName)).toContainText(CACHE);
    await expect(page).toHaveURL(/table=/);

    await page.locator(sel.panelShowMore).click();
    await expect(page).toHaveURL(/\/ets-tables\/[^?]+$/);
    await waitForLiveView(page);

    await expect(page.locator('h1')).toContainText(CACHE);
    await expect(page.locator(sel.details)).toContainText('Key position');
    await expect(page.locator(sel.details)).toContainText('set');

    await page.locator(sel.backToList).click();
    await expect(page.locator(sel.table)).toBeVisible();
  });

  test('the row arrow opens the details page directly', async ({ page }) => {
    await filterToMockTables(page);

    await row(page, EVENTS).locator('td[data-column="details"] a').click();
    await waitForLiveView(page);

    await expect(page.locator('h1')).toContainText(EVENTS);
    await expect(page.locator(sel.details)).toContainText('duplicate_bag');
    await expect(page.locator(sel.details)).toContainText('protected');
  });

  test('a private table is marked and its records stay unreadable', async ({
    page,
  }) => {
    await page.goto(`${listUrl}/${encodeURIComponent(SECRETS)}`);
    await waitForLiveView(page);

    await expect(page.locator(sel.detailsPrivateBadge)).toBeVisible();
    await expect(page.locator(sel.detailsPeek)).toBeDisabled();
    await expect(page.locator(sel.details)).toContainText('ordered_set');
  });

  test('an unknown table is reported, in the panel and on the details page', async ({
    page,
  }) => {
    await page.goto(`${listUrl}?table=no_such_table_here`);
    await waitForLiveView(page);
    await expect(page.locator(sel.panelNotFound)).toBeVisible();

    await page.goto(`${listUrl}/no_such_table_here`);
    await waitForLiveView(page);
    await expect(page.locator(sel.detailsError)).toContainText(
      'no_such_table_here'
    );
  });
});

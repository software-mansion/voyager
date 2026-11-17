import { test, expect } from '@playwright/test';
import { resolve } from 'node:path';
import { DatabaseSync, type SQLInputValue } from 'node:sqlite';
import { sel, ensureDisconnected, waitForLiveView } from './fixtures';

const DB_PATH = resolve(__dirname, '../../priv/db/voyager_e2e.db');
const UNREADABLE_NODE = 'unreadable@127.0.0.1';

// Encrypted with a different key than the one in config/e2e.exs.
const OTHER_KEY_CIPHERTEXT = Buffer.from(
  'AQpBRVMuR0NNLlYxJwdV9kEk66LvQixtRLdrgLL0CDrm9h0RazYjUIM902WRIFvnyxztAdQFuG1w',
  'base64'
);

function runSql(statement: string, ...params: SQLInputValue[]) {
  const db = new DatabaseSync(DB_PATH);
  try {
    db.prepare(statement).run(...params);
  } finally {
    db.close();
  }
}

test.describe('ConnectLive › secrets saved under another vault key', () => {
  test.beforeEach(async ({ page }) => {
    await ensureDisconnected(page);
    runSql(
      `INSERT INTO connections (node_name, cookie, last_connected_at, inserted_at, updated_at)
       VALUES (?, ?, datetime('now'), datetime('now'), datetime('now'))`,
      UNREADABLE_NODE,
      OTHER_KEY_CIPHERTEXT
    );
  });

  test.afterEach(() => {
    runSql('DELETE FROM connections WHERE node_name = ?', UNREADABLE_NODE);
  });

  test('warns, asks for the cookie again and clears after delete', async ({
    page,
  }) => {
    await page.goto('/');
    await waitForLiveView(page);

    const warning = page.locator(sel.unreadableSecrets);
    const row = page.locator(`${sel.recentConnections} li`, {
      hasText: UNREADABLE_NODE,
    });

    await expect(warning).toBeVisible();
    await expect(row.locator('[title="Cookie saved"]')).toHaveCount(0);

    await row.locator('[data-testid="fill-recent-btn"]').click();
    await expect(page.locator(sel.nodeNameInput)).toHaveValue(UNREADABLE_NODE);
    await expect(page.locator(sel.cookieInput)).toHaveValue('');

    await row.locator('button[title="Remove"]').click();
    await expect(row).toHaveCount(0);
    await expect(warning).toBeHidden();
  });
});

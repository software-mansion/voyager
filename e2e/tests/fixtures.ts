import { expect, type Page } from '@playwright/test';

export const NODE_NAME = 'test@127.0.0.1';
export const COOKIE = 'e2e_cookie';

export const sel = {
  connectForm: '#connect-form',
  nodeNameInput: '#conn_node_name',
  cookieInput: '#conn_cookie',
  connectBtn: '#connect-btn',
  disconnectFromConnect: '#disconnect-from-connect',
  recentConnections: '#recent-connections',
  nodeInfoContent: '#node-info-content',
  nodeInfoLoading: '#node-info-loading',
  stStatus: '#supervision-tree-status',
  stRefresh: '#refresh-interval-refresh-now-button',
  stBody: '#supervision-tree-body',
  stControls: '#supervision-tree-controls',
  stErrors: '#supervision-tree-errors',
};

export function fillRecentBtn(page: Page) {
  return page.locator(
    `${sel.recentConnections} [data-testid="fill-recent-btn"]`
  );
}

async function waitForLiveView(page: Page) {
  await page.waitForFunction(
    () =>
      (
        window as { liveSocket?: { isConnected: () => boolean } }
      ).liveSocket?.isConnected() === true
  );
}

/** Fill connect form fields and wait until LiveView has kept the values. */
export async function fillConnectForm(
  page: Page,
  nodeName: string,
  cookie: string
) {
  await page.locator(sel.nodeNameInput).fill(nodeName);
  await page.locator(sel.cookieInput).fill(cookie);
  await expect(page.locator(sel.nodeNameInput)).toHaveValue(nodeName);
  await expect(page.locator(sel.cookieInput)).toHaveValue(cookie);
}

/** Ensures the connect page is interactive (no active NodeSession). */
export async function ensureDisconnected(page: Page) {
  await page.goto('/');
  await waitForLiveView(page);

  const disconnect = page.locator(sel.disconnectFromConnect);
  if (await disconnect.isVisible()) {
    await disconnect.click();
    await expect(disconnect).toBeHidden();
    await waitForLiveView(page);
  }

  await expect(page.locator(sel.connectBtn)).toBeEnabled();
}

/** Ensures an active session to NODE_NAME (connects if needed). */
export async function ensureConnected(page: Page) {
  await page.goto('/');
  await waitForLiveView(page);

  if (await page.locator(sel.disconnectFromConnect).isVisible()) {
    return;
  }

  await fillConnectForm(page, NODE_NAME, COOKIE);
  await page.locator(sel.connectBtn).click();
  await expect(page).toHaveURL(/\/node\//);
}

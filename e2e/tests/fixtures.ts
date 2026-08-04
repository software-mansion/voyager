import { expect, type Page } from '@playwright/test';

export const NODE_NAME = 'test@127.0.0.1';
export const COOKIE = 'e2e_cookie';

export const SSH_USER = 'e2e_ssh_user';
export const SSH_HOST = 'bastion.e2e.test';
export const SSH_NODE_NAME = 'ssh-test@127.0.0.1';
export const SSH_COOKIE = 'e2e_ssh_cookie';

export const sel = {
  connectForm: '#direct-connect-form',
  connectBtn: '#direct-connect-btn',
  sshConnectForm: '#ssh-connect-form',
  sshConnectBtn: '#ssh-connect-btn',
  nodeNameInput: '#conn_node_name',
  cookieInput: '#conn_cookie',
  disconnectFromConnect: '#disconnect-from-connect',
  connectedIndicator: '#connected-indicator',
  recentConnections: '#direct-recent-connections',
  nodeInfoContent: '#node-info-content',
  nodeInfoLoading: '#node-info-loading',
  stStatus: '#supervision-tree-status',
  stRefresh: '#refresh-interval-refresh-now-button',
  stBody: '#supervision-tree-body',
  stControls: '#supervision-tree-controls',
  stErrors: '#supervision-tree-errors',
  modeDirect: '#mode-direct',
  modeSsh: '#mode-ssh',
  sshUserInput: '#ssh_ssh_user',
  sshHostInput: '#ssh_ssh_host',
  sshNodeNameInput: '#ssh_node_name',
  sshCookieInput: '#ssh_cookie',
  sshAuthAgent: '#ssh-auth-agent',
  sshAuthPassword: '#ssh-auth-password',
  sshPasswordInput: '#ssh_password',
  sshRecentConnections: '#ssh-recent-connections',
};

export function fillRecentBtn(page: Page) {
  return page.locator(
    `${sel.recentConnections} [data-testid="fill-recent-btn"]`
  );
}

export async function waitForLiveView(page: Page) {
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

export async function switchConnectMode(page: Page, modeSelector: string) {
  await expect(async () => {
    await page.locator(modeSelector).check();
    await expect(page.locator(modeSelector)).toBeChecked();
  }).toPass();
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

  await expect(async () => {
    const disconnect = page.locator(sel.disconnectFromConnect);
    if (await disconnect.isVisible()) {
      const indicator = page.locator(sel.connectedIndicator);
      if (await indicator.isVisible()) {
        const text = await indicator.textContent();
        if (text?.includes(NODE_NAME)) {
          return;
        }
      }

      await disconnect.click();
      await expect(disconnect).toBeHidden();
      await expect(page.locator(sel.connectBtn)).toBeEnabled();
      await waitForLiveView(page);
    }

    await fillConnectForm(page, NODE_NAME, COOKIE);
    await page.locator(sel.connectBtn).click({ timeout: 1000 });
    await expect(page).toHaveURL(/\/node\//);
  }).toPass();
}

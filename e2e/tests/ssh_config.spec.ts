import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test, expect, type Page } from '@playwright/test';
import {
  SSH_COOKIE,
  SSH_NODE_NAME,
  sel,
  ensureDisconnected,
  switchConnectMode,
  waitForLiveView,
} from './fixtures';

const CONFIG = `Host prod
  HostName 203.0.113.10
  User deploy
  Port 2222
  IdentityFile /e2e/keys/id_prod
  IdentityAgent /e2e/agent.sock
  ProxyJump bastion

Host github.com
  User git

Host *
  ForwardAgent no
`;

function hostButton(page: Page, testId: string, alias: string) {
  return page.locator(
    `${sel.sshConfigHosts} [data-testid="${testId}"][phx-value-alias="${alias}"]`
  );
}

async function importPickedFile(page: Page, configPath: string) {
  await page.locator(sel.sshConfigOpen).click();
  await page.locator(sel.sshConfigBrowse).click();
  await expect(page.locator(sel.sshConfigPathInput)).toHaveValue(configPath);
  await page.locator(sel.sshConfigImport).click();
}

test.describe('ConnectLive › SSH config import', () => {
  let dir: string;
  let configPath: string;

  test.beforeEach(async ({ page }) => {
    dir = await mkdtemp(join(tmpdir(), 'voyager-ssh-config-'));
    configPath = join(dir, 'ssh_config');
    await writeFile(configPath, CONFIG);

    // Playwright cannot drive the OS file dialog, so only the dialog's answer is stubbed.
    await page.addInitScript((path) => {
      (
        window as unknown as { __TAURI_INTERNALS__: unknown }
      ).__TAURI_INTERNALS__ = {
        invoke: async (command: string) =>
          command === 'plugin:dialog|open' ? path : null,
      };
    }, configPath);

    await ensureDisconnected(page);
    await switchConnectMode(page, sel.modeSsh);
  });

  test.afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  test('fills the form from a picked config file', async ({ page }) => {
    await page.locator(sel.sshNodeNameInput).fill(SSH_NODE_NAME);
    await page.locator(sel.sshCookieInput).fill(SSH_COOKIE);

    await importPickedFile(page, configPath);

    await expect(page.locator(sel.sshConfigNotice)).toContainText('proxyjump');
    await hostButton(page, 'fill-ssh-host-btn', 'prod').click();

    await expect(page.locator(sel.sshConfigModal)).toBeHidden();
    await expect(page.locator(sel.sshConfigFilledFrom)).toContainText('prod');
    await expect(page.locator(sel.sshHostInput)).toHaveValue('203.0.113.10');
    await expect(page.locator(sel.sshUserInput)).toHaveValue('deploy');
    await expect(page.locator(sel.sshPortInput)).toBeVisible();
    await expect(page.locator(sel.sshPortInput)).toHaveValue('2222');
    await expect(page.locator(sel.sshAgentSocketInput)).toHaveValue(
      '/e2e/agent.sock'
    );

    await expect(page.locator(sel.sshNodeNameInput)).toHaveValue(SSH_NODE_NAME);
    await expect(page.locator(sel.sshCookieInput)).toHaveValue(SSH_COOKIE);
    await expect(page.locator(sel.sshAuthAgent)).toBeChecked();

    await page.locator(sel.sshAuthKey).check();
    await expect(page.locator(sel.sshKeyPathInput)).toHaveValue(
      '/e2e/keys/id_prod'
    );
  });

  test('removes a host until the file is read again', async ({ page }) => {
    await importPickedFile(page, configPath);

    await hostButton(page, 'remove-ssh-host-btn', 'github.com').click();
    await expect(
      hostButton(page, 'fill-ssh-host-btn', 'github.com')
    ).toBeHidden();
    expect(await readFile(configPath, 'utf8')).toBe(CONFIG);

    await page.locator(sel.sshConfigReload).click();
    await expect(
      hostButton(page, 'fill-ssh-host-btn', 'github.com')
    ).toBeVisible();
  });

  test('remembers the picked file after a reload', async ({ page }) => {
    await importPickedFile(page, configPath);
    await expect(hostButton(page, 'fill-ssh-host-btn', 'prod')).toBeVisible();

    await page.reload();
    await waitForLiveView(page);
    await page.locator(sel.sshConfigOpen).click();

    await expect(hostButton(page, 'fill-ssh-host-btn', 'prod')).toBeVisible();
    await expect(page.locator(sel.sshConfigForm)).toBeHidden();
  });

  test('shows an error when the picked file cannot be read', async ({
    page,
  }) => {
    await rm(configPath);

    await importPickedFile(page, configPath);

    await expect(page.locator(sel.sshConfigForm)).toContainText(
      "Can't read this file"
    );
    await expect(page.locator(sel.sshConfigHosts)).toBeHidden();
  });
});

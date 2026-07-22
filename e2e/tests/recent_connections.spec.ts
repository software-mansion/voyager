import { test, expect } from '@playwright/test';
import { execSync } from 'child_process';
import path from 'path';
import { NODE_NAME, SSH_USER, SSH_NODE_NAME, sel } from './fixtures';

test.describe('ConnectLive › recent connections', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
  });

  test('shows connected node in recent connections', async ({ page }) => {
    await expect(page.locator(sel.recentConnections)).toBeVisible();
    await expect(page.locator(sel.recentConnections)).toContainText(NODE_NAME);
  });

  test('fills the form from a recent connection row', async ({ page }) => {
    await page
      .locator(`${sel.recentConnections} [data-testid="fill-recent-btn"]`)
      .first()
      .click();
    await expect(page.locator(sel.nodeNameInput)).toHaveValue(NODE_NAME);
  });
});

test.describe('ConnectLive › SSH recent connections', () => {
  test.beforeAll(() => {
    // No sshd in the e2e harness, so this seeds an SshConnection row directly
    execSync('mix run --no-start e2e/seed_ssh.exs', {
      cwd: path.resolve(__dirname, '..', '..'),
      env: { ...process.env, MIX_ENV: 'e2e' },
      stdio: 'inherit',
    });
  });

  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await page.locator(sel.modeSsh).check();
  });

  test('shows connected node in SSH recent connections', async ({ page }) => {
    await expect(page.locator(sel.sshRecentConnections)).toBeVisible();
    await expect(page.locator(sel.sshRecentConnections)).toContainText(
      SSH_NODE_NAME
    );
  });

  test('fills the SSH form from a recent connection row', async ({ page }) => {
    await page
      .locator(
        `${sel.sshRecentConnections} [data-testid="fill-ssh-recent-btn"]`
      )
      .first()
      .click();
    await expect(page.locator(sel.sshNodeNameInput)).toHaveValue(SSH_NODE_NAME);
    await expect(page.locator(sel.sshUserInput)).toHaveValue(SSH_USER);
  });
});

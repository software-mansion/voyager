import { test, expect } from '@playwright/test';
import { NODE_NAME, SSH_HOST, SSH_NODE_NAME, SSH_COOKIE, sel } from './fixtures';

test.describe('ConnectLive › form validation', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
  });

  test('renders the connection form', async ({ page }) => {
    await expect(page.locator(sel.connectForm)).toBeVisible();
    await expect(page.locator(sel.nodeNameInput)).toBeVisible();
    await expect(page.locator(sel.cookieInput)).toBeVisible();
    await expect(page.locator(sel.connectBtn)).toBeVisible();
  });

  test('shows required field errors on empty submission', async ({ page }) => {
    await page.locator(sel.connectBtn).click();
    await expect(page.locator(sel.connectForm)).toContainText("can't be blank");
  });

  test('shows format validation error for invalid node name', async ({
    page,
  }) => {
    await page.locator(sel.nodeNameInput).fill('invalid');
    await page.locator(sel.cookieInput).fill('somecookie');
    await page.locator(sel.connectBtn).click();
    await expect(page.locator(sel.connectForm)).toContainText(
      'name@host format'
    );
  });

  test('shows authentication error for wrong cookie', async ({ page }) => {
    await page.locator(sel.nodeNameInput).fill(NODE_NAME);
    await page.locator(sel.cookieInput).fill('wrong_cookie');
    await page.locator(sel.connectBtn).click();
    // A real distribution handshake with a mismatched cookie takes several
    // seconds (net_kernel's setup_time) plus the failure diagnosis round trip,
    // so this needs a longer timeout than the other (instant) validation checks.
    await expect(page.locator(sel.connectForm)).toContainText(
      'Authentication failed',
      { timeout: 15_000 }
    );
  });
});

test.describe('ConnectLive › SSH mode', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
  });

  test('starts in direct mode showing the direct form', async ({ page }) => {
    await expect(page.locator(sel.connectForm)).toBeVisible();
    await expect(page.locator(sel.sshConnectForm)).toHaveCount(0);
  });

  test('switching to SSH mode shows the SSH form', async ({ page }) => {
    await page.locator(sel.modeSsh).check();
    await expect(page.locator(sel.sshConnectForm)).toBeVisible();
    await expect(page.locator(sel.connectForm)).toHaveCount(0);
  });

  test('switching back to direct mode restores the direct form', async ({
    page,
  }) => {
    await page.locator(sel.modeSsh).check();
    await page.locator(sel.modeDirect).check();
    await expect(page.locator(sel.connectForm)).toBeVisible();
    await expect(page.locator(sel.sshConnectForm)).toHaveCount(0);
  });

  test('renders the SSH form fields', async ({ page }) => {
    await page.locator(sel.modeSsh).check();
    await expect(page.locator(sel.sshUserInput)).toBeVisible();
    await expect(page.locator(sel.sshHostInput)).toBeVisible();
    await expect(page.locator(sel.sshNodeNameInput)).toBeVisible();
    await expect(page.locator(sel.sshCookieInput)).toBeVisible();
    await expect(page.locator(sel.sshConnectBtn)).toBeVisible();
  });

  test('shows Agent auth selected by default with the password field hidden', async ({
    page,
  }) => {
    await page.locator(sel.modeSsh).check();
    await expect(page.locator(sel.sshAuthAgent)).toBeChecked();
    await expect(page.locator(sel.sshPasswordInput)).toHaveCount(0);
  });

  test('switching to password auth reveals the password field', async ({
    page,
  }) => {
    await page.locator(sel.modeSsh).check();
    await page.locator(sel.sshAuthPassword).check();
    await expect(page.locator(sel.sshPasswordInput)).toBeVisible();
  });

  test('switching back to agent hides the password field', async ({
    page,
  }) => {
    await page.locator(sel.modeSsh).check();
    await page.locator(sel.sshAuthPassword).check();
    await page.locator(sel.sshAuthAgent).check();
    await expect(page.locator(sel.sshPasswordInput)).toHaveCount(0);
  });

  test('shows required field errors on empty submission', async ({
    page,
  }) => {
    await page.locator(sel.modeSsh).check();
    await page.locator(sel.sshConnectBtn).click();
    await expect(page.locator(sel.sshConnectForm)).toContainText(
      "can't be blank"
    );
  });

  test('shows format validation error for invalid node name', async ({
    page,
  }) => {
    await page.locator(sel.modeSsh).check();
    await page.locator(sel.sshUserInput).fill('alice');
    await page.locator(sel.sshHostInput).fill(SSH_HOST);
    await page.locator(sel.sshNodeNameInput).fill('noatsign');
    await page.locator(sel.sshCookieInput).fill(SSH_COOKIE);
    await page.locator(sel.sshConnectBtn).click();
    await expect(page.locator(sel.sshConnectForm)).toContainText(
      'name@host format'
    );
  });

  test('requires the password field when password auth is selected', async ({
    page,
  }) => {
    await page.locator(sel.modeSsh).check();
    await page.locator(sel.sshAuthPassword).check();
    await page.locator(sel.sshUserInput).fill('alice');
    await page.locator(sel.sshHostInput).fill(SSH_HOST);
    await page.locator(sel.sshNodeNameInput).fill(SSH_NODE_NAME);
    await page.locator(sel.sshCookieInput).fill(SSH_COOKIE);
    await page.locator(sel.sshConnectBtn).click();
    await expect(page.locator(sel.sshPasswordInput)).toBeVisible();
    await expect(page.locator(sel.sshConnectForm)).toContainText(
      "can't be blank"
    );
  });
});

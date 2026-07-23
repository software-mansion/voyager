import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 4 : undefined,
  maxFailures: process.env.CI ? 5 : undefined,
  reporter: 'html',
  use: {
    baseURL: 'http://localhost:4001',
    trace: 'retain-on-failure',
  },

  webServer: {
    command:
      'cd .. && ELIXIR_ERL_OPTIONS="-epmd_module Elixir.Voyager.ProxyEpmd -pa $ebin" MIX_ENV=e2e mix phx.server',
    url: 'http://localhost:4001',
    reuseExistingServer: !process.env.CI,
    stdout: 'pipe',
    stderr: 'pipe',
  },

  projects: [
    {
      name: 'connect-form chromium',
      use: { ...devices['Desktop Chrome'] },
      testMatch: '**/connect_form.spec.ts',
    },
    {
      name: 'connect-form firefox',
      use: { ...devices['Desktop Firefox'] },
      testMatch: '**/connect_form.spec.ts',
    },

    {
      name: 'connect',
      use: { ...devices['Desktop Chrome'] },
      workers: 1,
      testMatch: '**/connect.spec.ts',
      dependencies: ['connect-form chromium', 'connect-form firefox'],
    },

    {
      name: 'node chromium',
      use: { ...devices['Desktop Chrome'] },
      testMatch: ['**/node_info.spec.ts', '**/recent_connections.spec.ts'],
      dependencies: ['connect'],
    },
    {
      name: 'node firefox',
      use: { ...devices['Desktop Firefox'] },
      testMatch: ['**/node_info.spec.ts', '**/recent_connections.spec.ts'],
      dependencies: ['connect'],
    },

    // Supervision Tree tests mutate shared state on the target node, so run them in order.
    {
      name: 'supervision-tree chromium',
      use: { ...devices['Desktop Chrome'] },
      fullyParallel: false,
      testMatch: '**/supervision_tree.spec.ts',
      dependencies: ['connect'],
    },
    {
      name: 'supervision-tree firefox',
      use: { ...devices['Desktop Firefox'] },
      fullyParallel: false,
      testMatch: '**/supervision_tree.spec.ts',
      dependencies: ['connect', 'supervision-tree chromium'],
    },
  ],
});

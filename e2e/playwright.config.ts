import { defineConfig, devices, type Project } from '@playwright/test';

// One project per browser; `serial` runs firefox after chromium instead of alongside it.
function pair(
  name: string,
  testMatch: string | string[],
  dependencies?: string[],
  { serial = false, ...options }: Project & { serial?: boolean } = {}
): Project[] {
  return [
    {
      name: `${name} chromium`,
      use: { ...devices['Desktop Chrome'] },
      testMatch,
      dependencies,
      ...options,
    },
    {
      name: `${name} firefox`,
      use: { ...devices['Desktop Firefox'] },
      testMatch,
      dependencies: serial ? [`${name} chromium`] : dependencies,
      ...options,
    },
  ];
}

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
      'cd .. && MIX_ENV=e2e mix compile && ebin="$PWD/_build/e2e/lib/voyager/ebin" && ELIXIR_ERL_OPTIONS="-epmd_module Elixir.Voyager.ProxyEpmd -pa $ebin" MIX_ENV=e2e mix phx.server',
    url: 'http://localhost:4001',
    reuseExistingServer: !process.env.CI,
    stdout: 'pipe',
    stderr: 'pipe',
  },

  projects: [
    ...pair('connect-form', '**/connect_form.spec.ts'),
    {
      name: 'connect',
      use: { ...devices['Desktop Chrome'] },
      workers: 1,
      testMatch: '**/connect.spec.ts',
      dependencies: ['connect-form chromium', 'connect-form firefox'],
    },
    ...pair(
      'recent-connections',
      '**/recent_connections.spec.ts',
      ['connect'],
      { serial: true, workers: 1 }
    ),
    ...pair('ets', '**/ets_tables.spec.ts', ['recent-connections firefox']),
    ...pair('node', '**/node_info.spec.ts', ['recent-connections firefox']),
    ...pair('sidebar', '**/sidebar.spec.ts', ['recent-connections firefox']),
    // Supervision Tree tests mutate shared state on the target node, so run them in order.
    ...pair(
      'supervision-tree',
      ['**/supervision_tree.spec.ts', '**/details_panel.spec.ts'],
      ['recent-connections firefox'],
      { serial: true, fullyParallel: false }
    ),
    // Processes tests flip the global pid format, so run them after every other project.
    ...pair(
      'processes',
      '**/processes.spec.ts',
      [
        'ets chromium',
        'ets firefox',
        'node chromium',
        'node firefox',
        'sidebar chromium',
        'sidebar firefox',
        'supervision-tree firefox',
      ],
      { serial: true }
    ),
  ],
});

defmodule Voyager.E2E.Case do
  @moduledoc false

  # The suite shares the app's global state (one NodeSession, the mock tree on the target
  # node, the pid format, saved connections). ExUnit runs every async module first, then the
  # sync ones one by one, in no defined order, so each module sets up its own connection state:
  #
  #   * async: the modules that only read a connected session (ets, node, sidebar), tracing
  #     (one browser, as the Tracer holds one session) and the supervision-tree modules.
  #     `group:` runs a spec's chromium and firefox modules in sequence, as they
  #     mutate the same tree.
  #   * sync: everything that disconnects or reconnects (connect_form, ssh_config, connect,
  #     unreadable_secrets, recent_connections) and processes (global pid format).
  use ExUnit.CaseTemplate

  # Each module runs once per device: Chromium and Firefox (`devices:` narrows it).
  # E2E_BROWSER=chromium|firefox runs only that browser's devices.
  @devices ["Desktop Chrome", "Desktop Firefox"]

  using opts do
    {devices, opts} = Keyword.pop(opts, :devices, @devices)
    browser = System.get_env("E2E_BROWSER")

    parameterize =
      for device <- devices,
          device = Playwright.device(device),
          browser in [nil, device[:default_browser_type]],
          do: Playwright.Test.parameters(device)

    opts = Keyword.put(opts, :parameterize, parameterize)

    quote do
      use Playwright.Case, unquote(Macro.escape(opts))
      import Voyager.E2E.Fixtures
    end
  end
end

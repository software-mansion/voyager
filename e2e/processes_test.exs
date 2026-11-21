defmodule Voyager.E2E.ProcessesTest do
  use Voyager.E2E.Case, async: false, project: "processes"

  @pid_links ~s|#processes-table tbody tr[id] td[data-column="pid"] a|
  @open_settings "#open-settings"
  @back "#settings-back"

  defp processes_url, do: "/node/#{node_name()}/processes"

  defp set_pid_format(page, format) do
    button = Page.locator(page, "#pid-format-#{format}")
    Locator.click!(button)
    Expect.to_have_attribute!(button, "aria-pressed", "true")
  end

  defp expect_pids(page, format) do
    links = Page.locator(page, @pid_links)
    links |> Locator.first() |> Expect.to_be_visible!()

    Expect.to_pass!(fn ->
      pids = links |> Locator.all_text_contents!() |> Enum.map(&String.trim/1)
      assert pids != []
      for pid <- pids, do: assert(pid =~ format)
    end)
  end

  describe "ProcessesLive › pid format" do
    setup %{page: page} do
      ensure_connected(page)

      # test.afterEach: reset the format to distribution, even when the test fails.
      on_exit(fn ->
        Page.goto!(page, "/settings")
        wait_for_live_view(page)
        set_pid_format(page, "distribution")
      end)

      :ok
    end

    test "switches the PID column from distribution to local form", %{page: page} do
      Page.goto!(page, "/settings")
      wait_for_live_view(page)
      set_pid_format(page, "distribution")

      Page.goto!(page, processes_url())
      wait_for_live_view(page)
      expect_pids(page, ~r/^<[1-9]\d*\.\d+\.\d+>$/)

      page |> Page.locator(@open_settings) |> Locator.click!()
      wait_for_live_view(page)
      set_pid_format(page, "local")

      page |> Page.locator(@back) |> Locator.click!()
      wait_for_live_view(page)
      Expect.to_have_url!(page, ~r"/processes")
      expect_pids(page, ~r/^<0\.\d+\.\d+>$/)
    end
  end
end

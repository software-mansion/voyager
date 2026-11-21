defmodule Voyager.E2E.TracingTest do
  # The Tracer holds one active session per Voyager, so a single browser runs these (a module's
  # tests run one at a time).
  use Voyager.E2E.Case,
    async: true,
    project: "tracing",
    devices: ["Desktop Chrome"]

  import Voyager.E2E.TreeHelpers

  @stop "#session-stop"
  @confirm_stop "#stop-session-modal-confirm"
  @resume "#session-resume"
  @rows ~s|#session-log-rows tr[id^="entry-"]|
  @live_badge "#session-log .badge-success"
  @indicator "#tracing-indicator"

  defp session_url(id),
    do: "/node/#{URI.encode(node_name(), &URI.char_unreserved?/1)}/tracing/#{id}"

  describe "TracingSessionLive" do
    setup %{page: page} do
      ensure_connected(page)
      on_exit(fn -> rpc_ok("mock_app_ctl trace_close []") end)
      :ok
    end

    test "opens a running session and streams its rows", %{page: page} do
      id = rpc("mock_app_ctl trace_session [false]")
      session_url = session_url(id)

      Page.goto!(page, session_url)
      wait_for_live_view(page)

      Expect.to_be_visible!(Page.locator(page, @stop))
      Expect.to_be_visible!(Page.locator(page, @live_badge))
      Expect.to_have_attribute!(Page.locator(page, @indicator), "href", session_url)

      rows = Page.locator(page, @rows)
      Expect.to_pass!(fn -> assert Locator.count!(rows) > 4 end)

      shown = Locator.count!(rows)
      Expect.to_pass!(fn -> assert Locator.count!(rows) > shown end)

      page |> Page.locator(@stop) |> Locator.click!()
      page |> Page.locator(@confirm_stop) |> Locator.click!()
      Expect.to_be_visible!(Page.locator(page, @resume))
      Expect.to_be_hidden!(Page.locator(page, @live_badge))
    end

    test "aligns a row tooltip to the call / result column", %{page: page} do
      id = rpc("mock_app_ctl trace_session [false]")
      Page.goto!(page, session_url(id))
      wait_for_live_view(page)

      term = page |> Page.locator(~s|#{@rows} [id$="-term"]|) |> Locator.first()
      Expect.to_be_visible!(term)
      page |> Page.locator(@stop) |> Locator.click!()
      page |> Page.locator(@confirm_stop) |> Locator.click!()
      Expect.to_be_visible!(Page.locator(page, @resume))
      # The stop row lands in a later log flush and shifts the rows under the pointer.
      Expect.to_be_visible!(Page.locator(page, @rows, has_text: "Stopped"))

      Locator.hover!(term)
      tip = Page.locator(page, "#log-term-tip")
      Expect.to_have_class!(tip, ~r/is-open/)

      column = term |> Locator.locator("xpath=ancestor::td") |> Locator.bounding_box!()
      tip_box = Locator.bounding_box!(tip)
      assert_in_delta tip_box.x, column.x, 0.5
    end
  end
end

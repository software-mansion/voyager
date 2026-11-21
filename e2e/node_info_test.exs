defmodule Voyager.E2E.NodeInfoTest do
  use Voyager.E2E.Case, async: true, project: "node"

  defp node_url, do: "/node/#{node_name()}"

  # same erl as the target node (e2e/node.sh)
  defp expected_otp_release, do: :otp_release |> :erlang.system_info() |> to_string()

  describe "NodeInfoLive" do
    setup %{page: page} do
      ensure_connected(page)
      Page.goto!(page, node_url())
      Expect.to_be_hidden!(Page.locator(page, sel(:node_info_loading)))
      Expect.to_be_visible!(Page.locator(page, sel(:node_info_content)))
      :ok
    end

    test "shows the connected node name and OTP", %{page: page} do
      Expect.to_contain_text!(Page.locator(page, "h1"), node_name())

      runtime_card =
        page
        |> Page.locator(sel(:node_info_content))
        |> Locator.locator(".card", has: Page.get_by_role(page, :heading, name: "Runtime"))

      otp_release =
        runtime_card
        |> Locator.get_by_text("OTP", exact: true)
        |> Locator.locator("..")
        |> Locator.locator("> div")
        |> Locator.nth(1)

      Expect.to_have_text!(otp_release, expected_otp_release())
    end
  end
end

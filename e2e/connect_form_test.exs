defmodule Voyager.E2E.ConnectFormTest do
  use Voyager.E2E.Case, async: false, project: "connect-form"

  describe "ConnectLive › form validation" do
    setup %{page: page} do
      ensure_disconnected(page)
      :ok
    end

    test "starts in direct mode showing the direct form", %{page: page} do
      Expect.to_be_visible!(Page.locator(page, sel(:connect_form)))
      Expect.to_be_hidden!(Page.locator(page, sel(:ssh_connect_form)))
    end

    test "renders the connection form", %{page: page} do
      Expect.to_be_visible!(Page.locator(page, sel(:connect_form)))
      Expect.to_be_visible!(Page.locator(page, sel(:node_name_input)))
      Expect.to_be_visible!(Page.locator(page, sel(:cookie_input)))
      Expect.to_be_visible!(Page.locator(page, sel(:connect_btn)))
    end

    test "shows required field errors on empty submission", %{page: page} do
      Locator.click!(Page.locator(page, sel(:connect_btn)))
      Expect.to_contain_text!(Page.locator(page, sel(:connect_form)), "can't be blank")
    end

    test "shows format validation error for invalid node name", %{page: page} do
      fill_connect_form(page, "invalid", "somecookie")
      Locator.click!(Page.locator(page, sel(:connect_btn)))
      Expect.to_contain_text!(Page.locator(page, sel(:connect_form)), "name@host format")
    end

    test "shows authentication error for wrong cookie", %{page: page} do
      fill_connect_form(page, node_name(), "wrong_cookie")
      Locator.click!(Page.locator(page, sel(:connect_btn)))
      # A real distribution handshake with a mismatched cookie takes several
      # seconds (net_kernel's setup_time) plus the failure diagnosis round trip,
      # so this needs a longer timeout than the other (instant) validation checks.
      Expect.to_contain_text!(Page.locator(page, sel(:connect_form)), "Authentication failed",
        timeout: 15_000
      )
    end
  end

  describe "ConnectLive › SSH mode" do
    setup %{page: page} do
      # Not a plain `goto("/")`: modules run in no defined order,
      # so a session may be connected.
      ensure_disconnected(page)
      :ok
    end

    test "switching to SSH mode shows the SSH form", %{page: page} do
      switch_connect_mode(page, sel(:mode_ssh))
      Expect.to_be_visible!(Page.locator(page, sel(:ssh_connect_form)))
      Expect.to_be_hidden!(Page.locator(page, sel(:connect_form)))
    end

    test "switching back to direct mode restores the direct form", %{page: page} do
      switch_connect_mode(page, sel(:mode_ssh))
      switch_connect_mode(page, sel(:mode_direct))
      Expect.to_be_visible!(Page.locator(page, sel(:connect_form)))
      Expect.to_be_hidden!(Page.locator(page, sel(:ssh_connect_form)))
    end

    test "renders the SSH form fields", %{page: page} do
      switch_connect_mode(page, sel(:mode_ssh))
      Expect.to_be_visible!(Page.locator(page, sel(:ssh_user_input)))
      Expect.to_be_visible!(Page.locator(page, sel(:ssh_host_input)))
      Expect.to_be_visible!(Page.locator(page, sel(:ssh_node_name_input)))
      Expect.to_be_visible!(Page.locator(page, sel(:ssh_cookie_input)))
      Expect.to_be_visible!(Page.locator(page, sel(:ssh_connect_btn)))
    end

    test "shows Agent auth selected by default with the password field hidden", %{page: page} do
      switch_connect_mode(page, sel(:mode_ssh))
      Expect.to_be_checked!(Page.locator(page, sel(:ssh_auth_agent)))
      Expect.to_be_hidden!(Page.locator(page, sel(:ssh_password_input)))
    end

    test "switching to password auth reveals the password field", %{page: page} do
      switch_connect_mode(page, sel(:mode_ssh))
      Locator.check!(Page.locator(page, sel(:ssh_auth_password)))
      Expect.to_be_visible!(Page.locator(page, sel(:ssh_password_input)))
    end

    test "switching back to agent hides the password field", %{page: page} do
      switch_connect_mode(page, sel(:mode_ssh))
      Locator.check!(Page.locator(page, sel(:ssh_auth_password)))
      Locator.check!(Page.locator(page, sel(:ssh_auth_agent)))
      Expect.to_be_hidden!(Page.locator(page, sel(:ssh_password_input)))
    end

    test "shows required field errors on empty submission", %{page: page} do
      switch_connect_mode(page, sel(:mode_ssh))
      Locator.click!(Page.locator(page, sel(:ssh_connect_btn)))
      Expect.to_contain_text!(Page.locator(page, sel(:ssh_connect_form)), "can't be blank")
    end

    test "shows format validation error for invalid node name", %{page: page} do
      switch_connect_mode(page, sel(:mode_ssh))
      Locator.fill!(Page.locator(page, sel(:ssh_user_input)), "alice")
      Locator.fill!(Page.locator(page, sel(:ssh_host_input)), ssh_host())
      Locator.fill!(Page.locator(page, sel(:ssh_node_name_input)), "noatsign")
      Locator.fill!(Page.locator(page, sel(:ssh_cookie_input)), ssh_cookie())
      Locator.click!(Page.locator(page, sel(:ssh_connect_btn)))
      Expect.to_contain_text!(Page.locator(page, sel(:ssh_connect_form)), "name@host format")
    end

    test "requires the password field when password auth is selected", %{page: page} do
      switch_connect_mode(page, sel(:mode_ssh))
      Locator.check!(Page.locator(page, sel(:ssh_auth_password)))
      Locator.fill!(Page.locator(page, sel(:ssh_user_input)), "alice")
      Locator.fill!(Page.locator(page, sel(:ssh_host_input)), ssh_host())
      Locator.fill!(Page.locator(page, sel(:ssh_node_name_input)), ssh_node_name())
      Locator.fill!(Page.locator(page, sel(:ssh_cookie_input)), ssh_cookie())
      Locator.click!(Page.locator(page, sel(:ssh_connect_btn)))
      Expect.to_be_visible!(Page.locator(page, sel(:ssh_password_input)))
      Expect.to_contain_text!(Page.locator(page, sel(:ssh_connect_form)), "can't be blank")
    end
  end
end

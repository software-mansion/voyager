defmodule Voyager.E2E.Fixtures do
  @moduledoc false
  alias Playwright.Expect
  alias Playwright.Locator
  alias Playwright.Page

  def node_name, do: "test@127.0.0.1"
  def node_name_v6, do: "test6@::1"
  def cookie, do: "e2e_cookie"

  def ssh_host, do: "bastion.e2e.test"
  def ssh_node_name, do: "ssh-test@127.0.0.1"
  def ssh_cookie, do: "e2e_ssh_cookie"

  @sel %{
    connect_form: "#direct-connect-form",
    connect_btn: "#direct-connect-btn",
    ssh_connect_form: "#ssh-connect-form",
    ssh_connect_btn: "#ssh-connect-btn",
    node_name_input: "#conn_node_name",
    cookie_input: "#conn_cookie",
    disconnect_from_connect: "#disconnect-from-connect",
    connected_indicator: "#connected-indicator",
    recent_connections: "#direct-recent-connections",
    node_info_content: "#node-info-content",
    node_info_loading: "#node-info-loading",
    st_status: "#supervision-tree-status",
    st_refresh: "#refresh-interval-refresh-now-button",
    st_body: "#supervision-tree-body",
    st_controls: "#supervision-tree-controls",
    st_errors: "#supervision-tree-errors",
    mode_direct: "#mode-direct",
    mode_ssh: "#mode-ssh",
    ssh_user_input: "#ssh_ssh_user",
    ssh_host_input: "#ssh_ssh_host",
    ssh_node_name_input: "#ssh_node_name",
    ssh_cookie_input: "#ssh_cookie",
    ssh_auth_agent: "#ssh-auth-agent",
    ssh_auth_password: "#ssh-auth-password",
    ssh_password_input: "#ssh_password",
    ssh_recent_connections: "#ssh-recent-connections",
    unreadable_secrets: "#unreadable-secrets",
    ssh_auth_key: "#ssh-auth-key",
    ssh_port_input: "#ssh_ssh_port",
    ssh_key_path_input: "#ssh_key_path",
    ssh_agent_socket_input: "#ssh_agent_socket_path",
    ssh_config_open: "#ssh-config-open",
    ssh_config_filled_from: "#ssh-config-filled-from",
    ssh_config_modal: "#ssh-config-modal",
    ssh_config_form: "#ssh-config-modal-form",
    ssh_config_path_input: "#ssh_config_path",
    ssh_config_browse: "#ssh_config_path-browse",
    ssh_config_import: "#ssh-config-modal-import",
    ssh_config_reload: "#ssh-config-modal-reload",
    ssh_config_hosts: "#ssh-config-modal-hosts",
    ssh_config_notice: "#ssh-config-notice"
  }

  def sel(key), do: Map.fetch!(@sel, key)

  def fill_recent_btn(page) do
    Page.locator(page, "#{sel(:recent_connections)} [data-testid=\"fill-recent-btn\"]")
  end

  def wait_for_live_view(page) do
    Page.wait_for_function!(page, "() => window.liveSocket?.isConnected() === true")
  end

  @doc "Fill connect form fields and wait until LiveView has kept the values."
  def fill_connect_form(page, node_name, cookie) do
    name_input = Page.locator(page, sel(:node_name_input))
    cookie_input = Page.locator(page, sel(:cookie_input))

    Expect.to_pass!(
      fn ->
        Locator.fill!(name_input, node_name, timeout: 500)
        Locator.fill!(cookie_input, cookie, timeout: 500)
        Expect.to_have_value!(name_input, node_name, timeout: 500)
        Expect.to_have_value!(cookie_input, cookie, timeout: 500)
      end,
      timeout: 2000
    )
  end

  def switch_connect_mode(page, mode_selector) do
    mode = Page.locator(page, mode_selector)

    Expect.to_pass!(fn ->
      Locator.check!(mode)
      Expect.to_be_checked!(mode)
    end)
  end

  @doc "Ensures the connect page is interactive (no active NodeSession)."
  def ensure_disconnected(page) do
    Page.goto!(page, "/")
    wait_for_live_view(page)

    disconnect = Page.locator(page, sel(:disconnect_from_connect))

    if Locator.is_visible!(disconnect) do
      Locator.click!(disconnect)
      Expect.to_be_hidden!(disconnect)
      # Disconnect keeps SSH mode; reload `/` so Direct's connectBtn is visible again.
      Page.goto!(page, "/")
      wait_for_live_view(page)
    end

    Expect.to_be_enabled!(Page.locator(page, sel(:connect_btn)))
  end

  @doc "Ensures an active session to the node (connects if needed)."
  def ensure_connected(page) do
    Page.goto!(page, "/")
    wait_for_live_view(page)

    Expect.to_pass!(fn ->
      disconnect = Page.locator(page, sel(:disconnect_from_connect))

      if !connected_to_node?(page, disconnect), do: connect_to_node(page, disconnect)
    end)
  end

  defp connect_to_node(page, disconnect) do
    if Locator.is_visible!(disconnect) do
      Locator.click!(disconnect)
      Expect.to_be_hidden!(disconnect)
      Expect.to_be_enabled!(Page.locator(page, sel(:connect_btn)))
      wait_for_live_view(page)
    end

    fill_connect_form(page, node_name(), cookie())
    Locator.click!(Page.locator(page, sel(:connect_btn)), timeout: 1000)
    Expect.to_have_url!(page, ~r"/node/")
  end

  defp connected_to_node?(page, disconnect) do
    if Locator.is_visible!(disconnect) do
      indicator = Page.locator(page, sel(:connected_indicator))

      Locator.is_visible!(indicator) and
        String.contains?(Locator.text_content!(indicator) || "", node_name())
    else
      false
    end
  end
end

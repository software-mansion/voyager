defmodule Voyager.E2E.SshConfigTest do
  # The saved config path is global, and a session started by `connect` disables the form.
  use Voyager.E2E.Case, async: false, project: "ssh-config"

  @config """
  Host prod
    HostName 203.0.113.10
    User deploy
    Port 2222
    IdentityFile /e2e/keys/id_prod
    IdentityAgent /e2e/agent.sock
    ProxyJump bastion

  Host github.com
    User git

  Host *
    ForwardAgent no
  """

  defp host_button(page, test_id, host_alias) do
    Page.locator(
      page,
      ~s|#{sel(:ssh_config_hosts)} [data-testid="#{test_id}"][phx-value-alias="#{host_alias}"]|
    )
  end

  defp import_picked_file(page, config_path) do
    page |> Page.locator(sel(:ssh_config_open)) |> Locator.click!()
    page |> Page.locator(sel(:ssh_config_browse)) |> Locator.click!()
    Expect.to_have_value!(Page.locator(page, sel(:ssh_config_path_input)), config_path)
    page |> Page.locator(sel(:ssh_config_import)) |> Locator.click!()
  end

  describe "ConnectLive › SSH config import" do
    setup %{page: page} do
      dir =
        Path.join(System.tmp_dir!(), "voyager-ssh-config-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      config_path = Path.join(dir, "ssh_config")
      File.write!(config_path, @config)

      # Playwright cannot drive the OS file dialog, so only the dialog's answer is stubbed.
      Page.add_init_script!(page, """
      ((path) => {
        window.__TAURI_INTERNALS__ = {
          invoke: async (command) => (command === 'plugin:dialog|open' ? path : null),
        };
      })(#{JSON.encode!(config_path)})
      """)

      ensure_disconnected(page)
      switch_connect_mode(page, sel(:mode_ssh))
      %{config_path: config_path}
    end

    test "fills the form from a picked config file", %{page: page, config_path: config_path} do
      page |> Page.locator(sel(:ssh_node_name_input)) |> Locator.fill!(ssh_node_name())
      page |> Page.locator(sel(:ssh_cookie_input)) |> Locator.fill!(ssh_cookie())

      import_picked_file(page, config_path)

      Expect.to_contain_text!(Page.locator(page, sel(:ssh_config_notice)), "forwardagent")

      page
      |> Page.locator(
        ~s|#{sel(:ssh_config_hosts)} [data-alias="prod"] [data-testid="ssh-host-problems"]|
      )
      |> Locator.hover!()

      problems_tip = page |> Page.get_by_role(:tooltip) |> Locator.filter(has_text: "proxyjump")
      Expect.to_be_visible!(problems_tip)
      Expect.to_contain_text!(problems_tip, "Not supported")
      page |> host_button("fill-ssh-host-btn", "prod") |> Locator.click!()

      Expect.to_be_hidden!(Page.locator(page, sel(:ssh_config_modal)))
      Expect.to_contain_text!(Page.locator(page, sel(:ssh_config_filled_from)), "prod")
      Expect.to_have_value!(Page.locator(page, sel(:ssh_host_input)), "203.0.113.10")
      Expect.to_have_value!(Page.locator(page, sel(:ssh_user_input)), "deploy")
      Expect.to_be_visible!(Page.locator(page, sel(:ssh_port_input)))
      Expect.to_have_value!(Page.locator(page, sel(:ssh_port_input)), "2222")
      Expect.to_have_value!(Page.locator(page, sel(:ssh_agent_socket_input)), "/e2e/agent.sock")

      Expect.to_have_value!(Page.locator(page, sel(:ssh_node_name_input)), ssh_node_name())
      Expect.to_have_value!(Page.locator(page, sel(:ssh_cookie_input)), ssh_cookie())
      Expect.to_be_checked!(Page.locator(page, sel(:ssh_auth_agent)))

      page |> Page.locator(sel(:ssh_auth_key)) |> Locator.check!()
      Expect.to_have_value!(Page.locator(page, sel(:ssh_key_path_input)), "/e2e/keys/id_prod")
    end

    test "removes a host until the file is read again", %{page: page, config_path: config_path} do
      import_picked_file(page, config_path)

      page |> host_button("remove-ssh-host-btn", "github.com") |> Locator.click!()
      page |> host_button("fill-ssh-host-btn", "github.com") |> Expect.to_be_hidden!()
      assert File.read!(config_path) == @config

      page |> Page.locator(sel(:ssh_config_reload)) |> Locator.click!()
      page |> host_button("fill-ssh-host-btn", "github.com") |> Expect.to_be_visible!()
    end

    test "remembers the picked file after a reload", %{page: page, config_path: config_path} do
      import_picked_file(page, config_path)
      page |> host_button("fill-ssh-host-btn", "prod") |> Expect.to_be_visible!()

      Page.reload!(page)
      wait_for_live_view(page)
      page |> Page.locator(sel(:ssh_config_open)) |> Locator.click!()

      page |> host_button("fill-ssh-host-btn", "prod") |> Expect.to_be_visible!()
      Expect.to_be_hidden!(Page.locator(page, sel(:ssh_config_form)))
    end

    test "shows an error when the picked file cannot be read", %{
      page: page,
      config_path: config_path
    } do
      File.rm!(config_path)

      import_picked_file(page, config_path)

      Expect.to_contain_text!(Page.locator(page, sel(:ssh_config_form)), "Can't read this file")
      Expect.to_be_hidden!(Page.locator(page, sel(:ssh_config_hosts)))
    end
  end
end

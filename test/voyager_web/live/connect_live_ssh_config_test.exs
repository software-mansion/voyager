defmodule VoyagerWeb.ConnectLiveSshConfigTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Voyager.Fakes
  alias Voyager.NodeSession
  alias Voyager.Settings
  alias VoyagerWeb.ConnectLive.SshConfigImport
  alias VoyagerWeb.FormSchemas.SshConnectionParams

  @moduletag :tmp_dir

  @telemetry_event [:voyager, :ssh_config, :import]

  @config """
  Host prod
    HostName 10.0.0.5
    User deploy
    Port 2222
    IdentityFile /k/first
    IdentityFile /k/second
    IdentityAgent /a/agent.sock

  Host custom-port
    Port 2200

  Host default-port
    Port 22

  Host with-agent
    IdentityAgent /a/agent.sock

  Host bare
  """

  @prod %{
    alias: "prod",
    host_name: "10.0.0.5",
    user: "deploy",
    port: 2222,
    identity_files: [],
    identity_agent: nil
  }
  @bare %{
    alias: "bare",
    host_name: nil,
    user: nil,
    port: nil,
    identity_files: [],
    identity_agent: nil
  }

  setup do
    previous_state = :sys.get_state(NodeSession)
    Fakes.put_session(nil)
    on_exit(fn -> :sys.replace_state(NodeSession, fn _ -> previous_state end) end)
  end

  defp form(params) do
    params |> SshConnectionParams.changeset() |> Phoenix.Component.to_form(as: :ssh)
  end

  defp write_config!(dir, contents \\ @config) do
    path = Path.join(dir, "ssh_config")
    File.write!(path, contents)
    path
  end

  defp open_page(conn) do
    {:ok, view, _html} = live(conn, ~p"/?mode=ssh")
    view
  end

  defp open_modal(view), do: view |> element("#ssh-config-open") |> render_click()

  defp submit_path(view, path) do
    view
    |> element("#ssh-config-modal-form")
    |> render_submit(%{"ssh_config" => %{"path" => path}})
  end

  defp import_config(view, path) do
    open_modal(view)
    submit_path(view, path)
  end

  defp pick(view, host_alias) do
    view
    |> element(~s|[data-testid="fill-ssh-host-btn"][phx-value-alias="#{host_alias}"]|)
    |> render_click()
  end

  defp remove(view, host_alias) do
    view
    |> element(~s|[data-testid="remove-ssh-host-btn"][phx-value-alias="#{host_alias}"]|)
    |> render_click()
  end

  defp listed?(view, host_alias) do
    has_element?(view, ~s|#ssh-config-modal-hosts [phx-value-alias="#{host_alias}"]|)
  end

  defp type(view, params) do
    view |> element("#ssh-connect-form") |> render_change(%{"ssh" => params})
  end

  defp value?(view, id, value), do: has_element?(view, ~s|##{id}[value="#{value}"]|)

  describe "selected_host/2" do
    test "finds the host a fill produced" do
      for host <- [@prod, @bare] do
        form = form(SshConnectionParams.params_from_host(host))

        assert SshConfigImport.selected_host([@prod, @bare], form) == host
      end
    end

    test "matches the schema's default port" do
      form = form(%{"ssh_host" => "bare"})

      assert SshConfigImport.selected_host([@bare], form) == @bare
    end

    test "stops matching once a server field is edited" do
      params = @prod |> SshConnectionParams.params_from_host() |> Map.put("ssh_port", "22")

      assert SshConfigImport.selected_host([@prod], form(params)) == nil
    end

    test "ignores an edited key path" do
      params = @prod |> SshConnectionParams.params_from_host() |> Map.put("key_path", "/k/other")

      assert SshConfigImport.selected_host([@prod], form(params)) == @prod
    end

    test "returns nil before an import" do
      assert SshConfigImport.selected_host(nil, form(%{})) == nil
    end
  end

  describe "modal" do
    test "the button opens it and Close closes it", %{conn: conn} do
      view = open_page(conn)
      refute has_element?(view, "#ssh-config-modal")

      open_modal(view)
      assert has_element?(view, "#ssh-config-modal-form")

      view |> element("#ssh-config-modal-close") |> render_click()
      refute has_element?(view, "#ssh-config-modal")
    end

    test "keeps a typed path across re-renders", %{conn: conn} do
      view = open_page(conn)
      open_modal(view)

      view
      |> element("#ssh-config-modal-form")
      |> render_change(%{"ssh_config" => %{"path" => "/typed/path"}})

      assert value?(view, "ssh_config_path", "/typed/path")
    end
  end

  describe "import" do
    test "lists the hosts in the file", %{conn: conn, tmp_dir: dir} do
      view = open_page(conn)
      import_config(view, write_config!(dir))

      assert listed?(view, "prod")
      assert listed?(view, "bare")
      refute has_element?(view, "#ssh-config-modal-form")
    end

    test "a bad path shows the error and saves nothing", %{conn: conn, tmp_dir: dir} do
      view = open_page(conn)
      import_config(view, Path.join(dir, "missing"))

      assert has_element?(view, "input#ssh_config_path.input-error")
      refute has_element?(view, "#ssh-config-modal-hosts")
      assert Settings.get(:ssh_config_path) == nil
    end

    test "tells an empty file apart from an unread one", %{conn: conn, tmp_dir: dir} do
      view = open_page(conn)
      import_config(view, write_config!(dir, ""))

      assert has_element?(view, "#ssh-config-modal-empty")
    end

    test "shows the note for unsupported settings", %{conn: conn, tmp_dir: dir} do
      view = open_page(conn)
      import_config(view, write_config!(dir, "Host prod\n  ProxyJump bastion\n"))

      assert has_element?(view, "#ssh-config-notice", "proxyjump")
    end

    test "hides the note without unsupported settings", %{conn: conn, tmp_dir: dir} do
      view = open_page(conn)
      import_config(view, write_config!(dir))

      refute has_element?(view, "#ssh-config-notice")
    end

    test "Change inside the modal brings the path form back", %{conn: conn, tmp_dir: dir} do
      path = write_config!(dir)
      view = open_page(conn)
      import_config(view, path)

      view |> element("#ssh-config-modal-edit-path") |> render_click()

      assert value?(view, "ssh_config_path", path)
      refute has_element?(view, "#ssh-config-modal-hosts")
    end
  end

  describe "picking a host" do
    setup %{conn: conn, tmp_dir: dir} do
      view = open_page(conn)
      import_config(view, write_config!(dir))
      %{view: view}
    end

    test "closes the modal and shows the filled-from row", %{view: view} do
      pick(view, "prod")

      refute has_element?(view, "#ssh-config-modal")
      assert has_element?(view, "#ssh-config-filled-from", "prod")
    end

    test "Change reopens the modal with the list and the selected host", %{view: view} do
      pick(view, "prod")
      open_modal(view)

      assert listed?(view, "prod")
      assert has_element?(view, ~s|#ssh-config-modal-hosts .icon-check|)
    end

    test "fills every field the host sets", %{view: view} do
      pick(view, "prod")

      assert value?(view, "ssh_ssh_host", "10.0.0.5")
      assert value?(view, "ssh_ssh_user", "deploy")
      assert value?(view, "ssh_ssh_port", "2222")
      assert value?(view, "ssh_agent_socket_path", "/a/agent.sock")
    end

    test "uses the first of several identity files", %{view: view} do
      pick(view, "prod")

      assert value?(view, "ssh_key_path", "/k/first")
    end

    test "keeps the auth method", %{view: view} do
      view |> element("#ssh-config-modal-close") |> render_click()
      type(view, %{"auth_method" => "password"})
      open_modal(view)
      pick(view, "prod")

      assert has_element?(view, "#ssh-auth-password[checked]")
    end

    test "keeps node name and cookie and clears the password", %{view: view} do
      view |> element("#ssh-config-modal-close") |> render_click()

      type(view, %{
        "node_name" => "demo@localhost",
        "cookie" => "secret",
        "auth_method" => "password",
        "password" => "hunter2"
      })

      open_modal(view)
      pick(view, "bare")

      assert value?(view, "ssh_node_name", "demo@localhost")
      assert value?(view, "ssh_cookie", "secret")
      refute value?(view, "ssh_password", "hunter2")
    end

    test "leaves nothing from the host picked before", %{view: view} do
      pick(view, "prod")
      open_modal(view)
      pick(view, "bare")

      assert value?(view, "ssh_ssh_host", "bare")
      assert value?(view, "ssh_ssh_port", "22")
      refute value?(view, "ssh_ssh_user", "deploy")
      refute value?(view, "ssh_key_path", "/k/first")
      refute value?(view, "ssh_agent_socket_path", "/a/agent.sock")
    end

    test "opens Advanced for a custom port", %{view: view} do
      assert has_element?(view, "#ssh-advanced.hidden")

      pick(view, "custom-port")
      refute has_element?(view, "#ssh-advanced.hidden")
    end

    test "opens Advanced for an agent socket", %{view: view} do
      pick(view, "with-agent")

      refute has_element?(view, "#ssh-advanced.hidden")
    end

    test "leaves Advanced closed for port 22 and no socket", %{view: view} do
      pick(view, "default-port")
      assert has_element?(view, "#ssh-advanced.hidden")

      open_modal(view)
      pick(view, "bare")
      assert has_element?(view, "#ssh-advanced.hidden")
    end
  end

  describe "removing a host" do
    test "drops it from the list until a reload", %{conn: conn, tmp_dir: dir} do
      view = open_page(conn)
      import_config(view, write_config!(dir))

      remove(view, "bare")
      refute listed?(view, "bare")
      assert listed?(view, "prod")

      view |> element("#ssh-config-modal-reload") |> render_click()
      assert listed?(view, "bare")
    end

    test "leaves the config file alone", %{conn: conn, tmp_dir: dir} do
      path = write_config!(dir)
      view = open_page(conn)
      import_config(view, path)

      remove(view, "bare")

      assert File.read!(path) == @config
    end
  end

  describe "saved path" do
    test "is read when the modal opens on a new page", %{conn: conn, tmp_dir: dir} do
      path = write_config!(dir)
      import_config(open_page(conn), path)
      assert Settings.get(:ssh_config_path) == path

      view = open_page(conn)
      open_modal(view)

      assert listed?(view, "prod")
    end

    test "is not read before the modal opens", %{conn: conn, tmp_dir: dir} do
      path = write_config!(dir)
      import_config(open_page(conn), path)
      ref = :telemetry_test.attach_event_handlers(self(), [@telemetry_event])
      on_exit(fn -> :telemetry.detach(ref) end)

      open_page(conn)

      refute_received {@telemetry_event, ^ref, _measurements, _metadata}
    end

    test "shows the error when the file has gone", %{conn: conn, tmp_dir: dir} do
      path = write_config!(dir)
      import_config(open_page(conn), path)
      File.rm!(path)

      view = open_page(conn)
      open_modal(view)

      assert value?(view, "ssh_config_path", path)
      assert has_element?(view, "input#ssh_config_path.input-error")
    end
  end

  describe "config_path/1" do
    test "uses ~/.ssh/config for a blank field" do
      assert SshConfigImport.config_path("") == "~/.ssh/config"
    end

    test "keeps any other path" do
      assert SshConfigImport.config_path("/k/config") == "/k/config"
    end
  end

  describe "telemetry" do
    setup do
      ref = :telemetry_test.attach_event_handlers(self(), [@telemetry_event])
      on_exit(fn -> :telemetry.detach(ref) end)
      %{ref: ref}
    end

    test "reports a successful read", %{conn: conn, tmp_dir: dir, ref: ref} do
      view = open_page(conn)
      import_config(view, write_config!(dir, "Host prod\n  ProxyJump bastion\nHost staging\n"))

      assert_received {@telemetry_event, ^ref, %{hosts: 2, unsupported: 1},
                       %{keywords: ["proxyjump"]}}
    end

    test "stays quiet for a failed read", %{conn: conn, tmp_dir: dir, ref: ref} do
      view = open_page(conn)
      import_config(view, Path.join(dir, "missing"))

      refute_received {@telemetry_event, ^ref, _measurements, _metadata}
    end
  end
end

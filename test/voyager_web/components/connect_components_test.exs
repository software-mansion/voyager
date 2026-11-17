defmodule VoyagerWeb.ConnectComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [to_form: 2]

  alias VoyagerWeb.ConnectComponents

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp text(html, selector) do
    html |> query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp count(html, selector), do: html |> query(selector) |> Enum.count()
  defp attr(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)

  defp path_field(attrs \\ []) do
    form = to_form(%{"key_path" => ""}, as: :ssh)

    render_component(
      &ConnectComponents.path_field/1,
      Keyword.merge([field: form[:key_path], label: "Identity file"], attrs)
    )
  end

  test "escapes apostrophes in the copied ssh-keygen command" do
    html =
      render_component(&ConnectComponents.host_key_changed_modal/1,
        id: "changed",
        host: "user@host",
        on_remove: "remove",
        on_dismiss: "dismiss",
        mismatch: %{
          host: "x'; id #",
          file: "/Users/O'Brien/.ssh/known_hosts",
          line: 1,
          key_type: "ED25519",
          fingerprint: "SHA256:abc",
          removable: false
        }
      )

    command = text(html, "#changed-command")
    args = String.replace_prefix(command, "ssh-keygen ", "")

    {out, 0} =
      System.cmd("sh", ["-c", "set -- #{args}; printf '%s\\n' \"$2\" \"$4\""])

    assert out == "/Users/O'Brien/.ssh/known_hosts\nx'; id #\n"
  end

  describe "path_field/1" do
    test "renders Browse disabled and wired to the input" do
      html = path_field()

      assert count(html, "button#ssh_key_path-browse[disabled]") == 1
      assert count(html, "#ssh_key_path-browse[phx-hook]") == 1
      assert attr(html, "#ssh_key_path-browse", "data-input-id") == ["ssh_key_path"]
      assert count(html, "input#ssh_key_path") == 1
    end

    test "starts browsing in the user's ~/.ssh" do
      assert attr(path_field(), "#ssh_key_path-browse", "data-default-path") ==
               [Path.expand("~/.ssh")]
    end

    test "limits the tooltip to runs outside the desktop app" do
      assert attr(path_field(), "#ssh_key_path-browse-tip", "data-tooltip-show-when") ==
               ["browser"]
    end

    test "disabling it locks the button and the input" do
      assert count(path_field(), "#ssh_key_path-browse[data-locked]") == 0
      assert count(path_field(), "input#ssh_key_path[disabled]") == 0

      disabled = path_field(disabled: true)
      assert count(disabled, "#ssh_key_path-browse[data-locked]") == 1
      assert count(disabled, "input#ssh_key_path[disabled]") == 1
    end
  end

  defp ssh_host(attrs \\ %{}) do
    Map.merge(
      %{
        alias: "prod",
        host_name: nil,
        user: nil,
        port: nil,
        identity_files: [],
        identity_agent: nil,
        problems: []
      },
      attrs
    )
  end

  defp opener(attrs) do
    render_component(
      &ConnectComponents.ssh_config_opener/1,
      Keyword.merge([config_path: "/k/config", on_open: "open"], attrs)
    )
  end

  defp host_row(host, attrs \\ []) do
    render_component(
      &ConnectComponents.ssh_host_row/1,
      Keyword.merge([host: host, on_fill: "fill", on_remove: "remove"], attrs)
    )
  end

  defp modal(attrs) do
    render_component(
      &ConnectComponents.ssh_config_modal/1,
      Keyword.merge(
        [
          id: "modal",
          form: to_form(%{"path" => ""}, as: :ssh_config),
          config_path: "/k/config",
          on_close: "close",
          on_change_path: "change",
          on_edit_path: "edit",
          on_import: "import",
          on_reload: "reload",
          on_fill: "fill",
          on_remove: "remove"
        ],
        attrs
      )
    )
  end

  describe "ssh_config_opener/1" do
    test "shows the import button until a host is selected" do
      html = opener(selected: nil)

      assert count(html, "button#ssh-config-open") == 1
      assert count(html, "#ssh-config-filled-from") == 0
    end

    test "shows the selected host and its config path" do
      html = opener(selected: ssh_host())

      assert text(html, "#ssh-config-filled-from") =~ "prod"
      assert text(html, "#ssh-config-filled-from") =~ "/k/config"
      assert count(html, "#ssh-config-filled-from button#ssh-config-open") == 1
    end

    test "disables both states" do
      assert count(opener(selected: nil, disabled: true), "#ssh-config-open[disabled]") == 1

      assert count(opener(selected: ssh_host(), disabled: true), "#ssh-config-open[disabled]") ==
               1
    end
  end

  describe "ssh_config_modal/1" do
    test "shows only the path form before a file is read" do
      html = modal(hosts: nil)

      assert count(html, "#modal-form input#ssh_config_path") == 1
      assert count(html, "#modal-source") == 0
      assert count(html, "#modal-hosts") == 0
    end

    test "shows the source and the hosts after a read" do
      html = modal(hosts: [ssh_host(), ssh_host(%{alias: "staging"})])

      assert count(html, "#modal-form") == 0
      assert count(html, "#modal-source") == 1
      assert text(html, "#modal-source") =~ "/k/config"
      assert count(html, "#modal-hosts [data-testid=fill-ssh-host-btn]") == 2
    end

    test "tells an empty file apart from one not read yet" do
      assert count(modal(hosts: []), "#modal-empty") == 1
      assert count(modal(hosts: nil), "#modal-empty") == 0
    end

    test "marks only the selected host" do
      selected = ssh_host()
      html = modal(hosts: [selected, ssh_host(%{alias: "staging"})], selected: selected)

      assert count(html, "#modal-hosts .icon-check") == 1
    end

    test "shows the notice only with shared problems" do
      shared = [%{keyword: "proxyjump", type: :keyword}]

      assert count(modal(hosts: [], shared: shared), "#ssh-config-notice") == 1
      assert count(modal(hosts: [], shared: []), "#ssh-config-notice") == 0
    end
  end

  describe "ssh_config_notice/1" do
    test "groups keywords by reason and lists a keyword under each of its reasons" do
      html =
        render_component(&ConnectComponents.ssh_config_notice/1,
          unsupported: [
            %{keyword: "include", type: :block},
            %{keyword: "port", type: :value},
            %{keyword: "include", type: :value},
            %{keyword: "proxyjump", type: :keyword}
          ]
        )

      assert attr(html, "#ssh-config-notice-reasons > div", "id") == [
               "ssh-config-notice-reasons-keyword",
               "ssh-config-notice-reasons-value",
               "ssh-config-notice-reasons-block"
             ]

      assert text(html, "#ssh-config-notice-reasons-keyword dd") == "proxyjump"
      assert text(html, "#ssh-config-notice-reasons-value dd") == "port, include"
      assert text(html, "#ssh-config-notice-reasons-block dd") == "include"
      assert text(html, "#ssh-config-notice summary") =~ "4 settings ignored"
    end

    test "skips reasons without keywords" do
      html =
        render_component(&ConnectComponents.ssh_config_notice/1,
          unsupported: [%{keyword: "port", type: :value}]
        )

      assert attr(html, "#ssh-config-notice-reasons > div", "id") == [
               "ssh-config-notice-reasons-value"
             ]

      assert text(html, "#ssh-config-notice summary") =~ "1 setting ignored"
    end
  end

  describe "ssh_host_row/1" do
    test "shows the full address" do
      html = host_row(ssh_host(%{user: "deploy", host_name: "10.0.0.5", port: 2222}))

      assert text(html, "[data-testid=fill-ssh-host-btn]") =~ "deploy@10.0.0.5:2222"
    end

    test "falls back to the alias when only the alias is set" do
      assert text(host_row(ssh_host()), "[data-testid=fill-ssh-host-btn] .border") =~ "prod"
    end

    test "shows a badge for each auth value the host has" do
      assert text(host_row(ssh_host(%{identity_files: ["/k/a"]})), "button") =~ "key"
      assert text(host_row(ssh_host(%{identity_agent: "/a.sock"})), "button") =~ "agent"
      refute text(host_row(ssh_host(%{identity_agent: :none})), "button") =~ "agent"
    end

    test "marks a host with problems and names them by reason" do
      problems = [
        %{keyword: "port", type: :value},
        %{keyword: "proxyjump", type: :keyword},
        %{keyword: "hostname", type: :value}
      ]

      html = host_row(ssh_host(%{problems: problems}))

      assert text(html, "[data-testid=ssh-host-problems]") =~ "3"
      assert count(html, "[phx-hook=Tooltip] button[data-testid=ssh-host-problems]") == 1
      assert count(html, "[data-testid=fill-ssh-host-btn] [data-testid=ssh-host-problems]") == 0
      assert html =~ "proxyjump"
      assert html =~ "port, hostname"
    end

    test "gives each host its own tooltip id" do
      ids =
        for host_alias <- ["prod", "my host"] do
          html =
            host_row(ssh_host(%{alias: host_alias, problems: [%{keyword: "x", type: :keyword}]}))

          attr(html, "[phx-hook=Tooltip]", "id")
        end

      assert [[prod_id], [spaced_id]] = ids
      assert prod_id != spaced_id
      refute spaced_id =~ " "
    end

    test "does not mark a host without problems" do
      html = host_row(ssh_host())

      assert count(html, "[data-testid=ssh-host-problems]") == 0
      assert count(html, "[phx-hook=Tooltip]") == 0
    end

    test "passes the alias to both events" do
      html = host_row(ssh_host())

      assert attr(html, "[phx-click=fill]", "phx-value-alias") == ["prod"]
      assert attr(html, "[phx-click=remove]", "phx-value-alias") == ["prod"]
    end
  end
end

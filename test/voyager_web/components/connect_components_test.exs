defmodule VoyagerWeb.ConnectComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [to_form: 2]

  alias VoyagerWeb.ConnectComponents

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> query(selector) |> Enum.count()
  defp attr(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)

  defp path_field(attrs \\ []) do
    form = to_form(%{"key_path" => ""}, as: :ssh)

    render_component(
      &ConnectComponents.path_field/1,
      Keyword.merge([field: form[:key_path], label: "Identity file"], attrs)
    )
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
        identity_agent: nil
      },
      attrs
    )
  end

  defp text(html, selector), do: html |> query(selector) |> LazyHTML.text()

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

    test "shows the notice only with unsupported settings" do
      unsupported = [%{keyword: "proxyjump", type: :keyword}]

      assert count(modal(hosts: [], unsupported: unsupported), "#ssh-config-notice") == 1
      assert count(modal(hosts: [], unsupported: []), "#ssh-config-notice") == 0
    end
  end

  describe "ssh_config_notice/1" do
    test "lists a keyword reported under two types once" do
      html =
        render_component(&ConnectComponents.ssh_config_notice/1,
          unsupported: [
            %{keyword: "port", type: :value},
            %{keyword: "port", type: :keyword},
            %{keyword: "match", type: :block}
          ]
        )

      assert html |> text("#ssh-config-notice .font-mono") |> String.trim() == "port, match"
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

    test "passes the alias to both events" do
      html = host_row(ssh_host())

      assert attr(html, "[phx-click=fill]", "phx-value-alias") == ["prod"]
      assert attr(html, "[phx-click=remove]", "phx-value-alias") == ["prod"]
    end
  end
end

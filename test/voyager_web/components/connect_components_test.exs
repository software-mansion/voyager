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
end

defmodule VoyagerWeb.Components.ProcessComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias VoyagerWeb.Components.ProcessComponents
  alias VoyagerWeb.Formatters

  describe "process_link/1" do
    test "links to the pid on the node in the current url and keeps the sidebar mode" do
      pid = self()

      html =
        render_component(&ProcessComponents.process_link/1,
          id: "owner",
          pid: pid,
          current_url: "http://localhost/node/demo%40127.0.0.1/ets-tables/t?sidebar=compact"
        )

      [href] =
        html |> LazyHTML.from_fragment() |> LazyHTML.query("#owner") |> LazyHTML.attribute("href")

      pid_string = URI.encode_www_form(Formatters.format_pid(pid))

      assert href == "/node/demo%40127.0.0.1/processes/#{pid_string}?sidebar=compact"
    end
  end
end

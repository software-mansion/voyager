defmodule VoyagerWeb.HelpersTest do
  use ExUnit.Case, async: true

  alias VoyagerWeb.Helpers
  alias VoyagerWeb.Utils.URL

  describe "put_return_to/2" do
    test "points back at the current url and keeps the sidebar mode" do
      path = Helpers.put_return_to("/node/n/processes/p", "/node/n/processes?sidebar=full")

      assert URL.get_query_param(path, "return_to") == "/node/n/processes?sidebar=full"
      assert URL.get_query_param(path, "sidebar") == "full"
    end

    test "goes back one hop instead of nesting the current return_to" do
      current_url = "/node/n/processes/a?return_to=%2Fnode%2Fn%2Fprocesses&tab=relations"
      path = Helpers.put_return_to("/node/n/processes/b", current_url)

      assert URL.get_query_param(path, "return_to") == "/node/n/processes/a?tab=relations"
    end

    test "leaves the path alone without a current url" do
      assert Helpers.put_return_to("/node/n/processes/b", nil) == "/node/n/processes/b"
    end
  end
end

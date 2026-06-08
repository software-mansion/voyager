defmodule Voyager.Services.RemoteNodeConnectorTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.RemoteNodeConnector

  describe "parse_port/2" do
    test "parses a single-node epmd -names output" do
      output = """
      epmd: up and running on port 4369 with data:
      name app at port 41234
      """

      assert {:ok, 41_234} = RemoteNodeConnector.parse_port(output, "app")
    end

    test "picks the requested name out of multiple" do
      output = """
      epmd: up and running on port 4369 with data:
      name other at port 99
      name app at port 41234
      name third at port 55555
      """

      assert {:ok, 41_234} = RemoteNodeConnector.parse_port(output, "app")
    end

    test "returns :node_not_found when the name is absent" do
      output = "epmd: up and running on port 4369\nname other at port 99\n"

      assert {:error, {:node_not_found, "missing", ^output}} =
               RemoteNodeConnector.parse_port(output, "missing")
    end

    test "returns :node_not_found on empty output" do
      assert {:error, {:node_not_found, "x", ""}} = RemoteNodeConnector.parse_port("", "x")
    end

    test "does not match a name that is only a prefix of another" do
      output = "name appserver at port 41234\n"

      assert {:error, {:node_not_found, "app", _}} = RemoteNodeConnector.parse_port(output, "app")
    end

    test "escapes regex metacharacters in the node name" do
      output = "name a.b+c at port 41234\n"

      assert {:ok, 41_234} = RemoteNodeConnector.parse_port(output, "a.b+c")
      assert {:error, _} = RemoteNodeConnector.parse_port(output, "axbxc")
    end
  end

  describe "connect/5" do
    @tag :capture_log
    test "returns an error when the SSH host is unreachable" do
      result =
        RemoteNodeConnector.connect(
          "nobody",
          "127.0.0.1",
          "no_such_node",
          {:password, "x"},
          ssh_port: 1
        )

      assert match?({:error, _}, result)
    end
  end
end

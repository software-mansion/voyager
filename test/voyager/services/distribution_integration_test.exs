defmodule Voyager.Services.DistributionIntegrationTest do
  use Voyager.DataCase, async: false

  alias Voyager.Services.Distribution

  @moduletag :integration

  setup_all do
    unless System.find_executable("epmd") do
      raise "epmd executable not found on PATH; required to run distributed tests"
    end

    case System.cmd("epmd", ["-daemon"]) do
      {_output, 0} -> :ok
      {output, status} -> raise "epmd -daemon exited with status #{status}: #{output}"
    end
  end

  describe "ensure_distributed/1" do
    setup do
      on_exit(fn -> if Node.alive?(), do: :net_kernel.stop() end)
    end

    test "starts distribution with a :longnames node pinned to 127.0.0.1" do
      assert :ok = Distribution.ensure_distributed(:longnames)

      assert {:ok, "voyager", "127.0.0.1"} =
               Node.self() |> Atom.to_string() |> Distribution.split_node_name()
    end

    test "starts distribution with a :shortnames node pinned to localhost" do
      assert :ok = Distribution.ensure_distributed(:shortnames)

      assert {:ok, "voyager", "localhost"} =
               Node.self() |> Atom.to_string() |> Distribution.split_node_name()
    end

    test "restarts distribution under the new host when name_type changes" do
      assert :ok = Distribution.ensure_distributed(:longnames)
      assert :ok = Distribution.ensure_distributed(:shortnames)

      assert {:ok, "voyager", "localhost"} =
               Node.self() |> Atom.to_string() |> Distribution.split_node_name()
    end

    test "rejects an invalid name_type" do
      assert {:error, :invalid_name_type} = Distribution.ensure_distributed(:invalid)
    end
  end
end

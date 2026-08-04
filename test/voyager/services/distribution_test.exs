defmodule Voyager.Services.DistributionTest do
  use Voyager.DataCase, async: false

  alias Voyager.Services.Distribution

  describe "split_node_name/1" do
    test "splits name@host into its parts" do
      assert {:ok, "myapp", "10.0.0.5"} = Distribution.split_node_name("myapp@10.0.0.5")
    end

    test "keeps the host intact when it contains an @-free remainder" do
      assert {:ok, "myapp", "host@weird"} = Distribution.split_node_name("myapp@host@weird")
    end

    test "errors when there is no @ separator" do
      assert {:error, {:invalid_node_format, "noatsign"}} =
               Distribution.split_node_name("noatsign")
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
      assert {:error, :invalid_name_type} = Distribution.ensure_distributed(:bogus)
    end
  end
end

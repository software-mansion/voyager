defmodule Voyager.Services.DistributionTest do
  use ExUnit.Case, async: true

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
end

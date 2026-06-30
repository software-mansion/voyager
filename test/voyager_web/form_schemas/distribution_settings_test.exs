defmodule VoyagerWeb.FormSchemas.DistributionSettingsTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset
  import Voyager.TestUtils

  alias VoyagerWeb.FormSchemas.DistributionSettings

  describe "changeset/1" do
    test "defaults distribution_suffix to an empty string" do
      changeset = DistributionSettings.changeset(%{})

      assert changeset.valid?
      assert get_field(changeset, :distribution_suffix) == ""
    end

    test "trims distribution_suffix" do
      changeset = DistributionSettings.changeset(%{"distribution_suffix" => "  _dev  "})

      assert changeset.valid?
      assert get_field(changeset, :distribution_suffix) == "_dev"
    end

    test "rejects nil distribution_suffix" do
      changeset = DistributionSettings.changeset(%{"distribution_suffix" => nil})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).distribution_suffix
    end

    test "accepts letters, numbers, underscores, and hyphens" do
      changeset = DistributionSettings.changeset(%{"distribution_suffix" => "Dev_123-node"})

      assert changeset.valid?
      assert get_field(changeset, :distribution_suffix) == "Dev_123-node"
    end

    test "rejects unsupported characters" do
      changeset = DistributionSettings.changeset(%{"distribution_suffix" => "bad.suffix"})

      refute changeset.valid?

      assert "Use only letters, numbers, underscores, or hyphens" in errors_on(changeset).distribution_suffix
    end

    test "rejects suffixes longer than 64 characters" do
      changeset =
        DistributionSettings.changeset(%{
          "distribution_suffix" => String.duplicate("a", 65)
        })

      refute changeset.valid?

      assert Enum.any?(
               errors_on(changeset).distribution_suffix,
               &String.contains?(&1, "should be at most 64")
             )
    end
  end
end

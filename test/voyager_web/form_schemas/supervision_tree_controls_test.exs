defmodule VoyagerWeb.FormSchemas.SupervisionTreeControlsTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset
  import Voyager.TestUtils

  alias VoyagerWeb.FormSchemas.SupervisionTreeControls

  @available_apps [:kernel, :stdlib, :elixir]
  @available_strings ["kernel", "stdlib", "elixir"]

  describe "changeset/2" do
    test "defaults are applied correctly" do
      changeset = SupervisionTreeControls.changeset(%{}, @available_apps)
      assert changeset.changes == %{}
      assert SupervisionTreeControls.default_depth() == 3
    end

    test "filters out unknown apps" do
      attrs = %{"apps" => ["kernel", "unknown", "elixir"]}
      changeset = SupervisionTreeControls.changeset(attrs, @available_apps)
      assert get_field(changeset, :apps) == ["kernel", "elixir"]
    end

    test "validates depth is >= 2" do
      changeset = SupervisionTreeControls.changeset(%{"depth" => 1}, @available_apps)
      refute changeset.valid?
      assert "min 2" in errors_on(changeset).depth

      changeset = SupervisionTreeControls.changeset(%{"depth" => 2}, @available_apps)
      assert changeset.valid?
    end

    test "validates depth is a number" do
      changeset = SupervisionTreeControls.changeset(%{"depth" => "abc"}, @available_apps)
      refute changeset.valid?
    end
  end

  describe "apps_from_changeset/1" do
    test "converts valid strings to atoms and detects truncation" do
      changeset =
        SupervisionTreeControls.changeset(%{"apps" => @available_strings}, @available_apps)

      {apps, truncated?} = SupervisionTreeControls.apps_from_changeset(changeset)

      assert apps == [:kernel, :stdlib, :elixir]
      refute truncated?
    end

    test "handles truncation when apps exceed max_apps" do
      many_apps = Enum.map(1..25, &"app_#{&1}")
      # All these are "unknown" based on @available_apps so they would be filtered out
      # We need to include valid ones to test truncation
      valid_apps = ["kernel"]
      attrs = %{"apps" => valid_apps ++ many_apps}

      # We need to expand available apps for this test
      all_available = @available_apps ++ Enum.map(many_apps, &String.to_atom(&1))

      changeset = SupervisionTreeControls.changeset(attrs, all_available)
      {apps, truncated?} = SupervisionTreeControls.apps_from_changeset(changeset)

      assert length(apps) == SupervisionTreeControls.max_apps()
      assert truncated?
    end
  end
end

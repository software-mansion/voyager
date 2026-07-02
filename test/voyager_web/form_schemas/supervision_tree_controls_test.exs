defmodule VoyagerWeb.FormSchemas.SupervisionTreeControlsTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias VoyagerWeb.FormSchemas.SupervisionTreeControls

  @available_apps [:kernel, :stdlib, :elixir]

  describe "changeset/2" do
    test "defaults are applied correctly" do
      changeset = SupervisionTreeControls.changeset(%{}, @available_apps)
      assert changeset.changes == %{}
      assert SupervisionTreeControls.default_depth() == 3
    end

    test "filters out unknown apps" do
      attrs = %{"apps" => ["kernel", "unknown", "elixir"]}
      changeset = SupervisionTreeControls.changeset(attrs, @available_apps)
      assert get_field(changeset, :apps) == [:kernel, :elixir]
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

    test "validates apps length is <= 20" do
      apps = for i <- 1..21, do: String.to_atom("app_#{i}")
      attrs = %{"apps" => Enum.map(apps, &Atom.to_string/1)}

      changeset = SupervisionTreeControls.changeset(attrs, apps)
      refute changeset.valid?
      assert "Only 20 applications can be selected at once." in errors_on(changeset).apps

      changeset = SupervisionTreeControls.changeset(attrs, Enum.take(apps, 20))
      assert changeset.valid?
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end

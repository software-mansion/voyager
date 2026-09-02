defmodule VoyagerWeb.FormSchemas.EtsTableListControlsTest do
  use ExUnit.Case, async: true

  alias VoyagerWeb.FormSchemas.EtsTableListControls

  defp apply_attrs(attrs),
    do: EtsTableListControls.apply(EtsTableListControls.default(), attrs)

  describe "changeset/2" do
    test "accepts a timeout inside the bounds" do
      {min, max} = EtsTableListControls.timeout_bounds()

      for timeout <- [min, div(min + max, 2), max] do
        {controls, changeset} = apply_attrs(%{"timeout" => timeout})

        assert changeset.valid?
        assert controls.timeout == timeout
      end
    end

    test "rejects a timeout outside the bounds and keeps the previous value" do
      {min, max} = EtsTableListControls.timeout_bounds()

      for timeout <- [min - 1, max + 1] do
        {controls, changeset} = apply_attrs(%{"timeout" => timeout})

        refute changeset.valid?
        assert controls.timeout == EtsTableListControls.default().timeout
      end
    end

    test "an emptied timeout box reports itself instead of silently reverting" do
      {controls, changeset} = apply_attrs(%{"timeout" => ""})

      refute changeset.valid?
      assert controls.timeout == EtsTableListControls.default().timeout
    end

    test "trims the search term" do
      {controls, _changeset} = apply_attrs(%{"search" => "  cache  "})

      assert controls.search == "cache"
    end

    test "a null search from localStorage is survivable" do
      {controls, changeset} = apply_attrs(%{"search" => nil})

      assert changeset.valid?
      assert controls.search == ""
    end

    test "drops unknown columns" do
      {controls, _changeset} = apply_attrs(%{"columns" => ["type", "records"]})

      assert controls.columns == ["type"]
    end

    test "the search does not disturb an otherwise valid form" do
      {controls, changeset} = apply_attrs(%{"search" => "x", "timeout" => "999999"})

      refute changeset.valid?
      assert controls.search == "x"
    end
  end

  describe "columns/1" do
    test "shows the main columns by default, with the rest available" do
      assert EtsTableListControls.columns(EtsTableListControls.default()) ==
               [:name, :memory, :protection, :type, :size, :owner]

      assert :heir in EtsTableListControls.optional_columns()
      assert :read_concurrency in EtsTableListControls.optional_columns()
    end

    test "always includes the required columns" do
      {controls, _changeset} = apply_attrs(%{"columns" => []})

      assert EtsTableListControls.columns(controls) == EtsTableListControls.required_columns()
    end

    test "keeps the selected columns in display order" do
      {controls, _changeset} = apply_attrs(%{"columns" => ["owner", "type"]})

      assert EtsTableListControls.columns(controls) == [:name, :memory, :type, :owner]
    end
  end
end

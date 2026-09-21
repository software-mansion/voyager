defmodule VoyagerWeb.FormSchemas.ProcessListControlsTest do
  use ExUnit.Case, async: true

  alias VoyagerWeb.FormSchemas.ProcessListControls

  defp apply_attrs(attrs), do: ProcessListControls.apply(ProcessListControls.default(), attrs)

  describe "changeset/2" do
    test "accepts a selectable limit" do
      for limit <- ProcessListControls.limit_options() do
        {controls, changeset} = apply_attrs(%{"limit" => limit})

        assert changeset.valid?
        assert controls.limit == limit
      end
    end

    test "rejects a limit outside the options" do
      {controls, changeset} = apply_attrs(%{"limit" => 7})

      refute changeset.valid?
      # The rest of the form still applies, so the table stays usable.
      assert controls.limit == ProcessListControls.default().limit
    end

    test "accepts a timeout inside the bounds" do
      {min, max} = ProcessListControls.timeout_bounds()

      for timeout <- [min, div(min + max, 2), max] do
        {controls, changeset} = apply_attrs(%{"timeout" => timeout})

        assert changeset.valid?
        assert controls.timeout == timeout
      end
    end

    test "rejects a timeout outside the bounds" do
      {min, max} = ProcessListControls.timeout_bounds()

      for timeout <- [min - 1, max + 1] do
        {_controls, changeset} = apply_attrs(%{"timeout" => timeout})

        refute changeset.valid?
      end
    end

    test "an emptied number box reports itself instead of silently reverting" do
      for field <- ~w(limit timeout) do
        {controls, changeset} = apply_attrs(%{field => ""})

        refute changeset.valid?
        # The last valid value keeps driving fetches while the error shows.
        assert Map.get(controls, String.to_existing_atom(field)) ==
                 Map.get(ProcessListControls.default(), String.to_existing_atom(field))
      end
    end

    test "trims the search term" do
      {controls, _changeset} = apply_attrs(%{"search" => "  gen  "})

      assert controls.search == "gen"
    end

    test "drops unknown columns" do
      {controls, _changeset} = apply_attrs(%{"columns" => ["status", "messages"]})

      assert "status" in controls.columns
      refute "messages" in controls.columns
    end
  end

  describe "attrs/1" do
    test "always includes the required attributes" do
      {controls, _changeset} = apply_attrs(%{"columns" => []})

      for required <- ProcessListControls.required_columns() do
        assert required in ProcessListControls.attrs(controls)
      end
    end

    test "includes the selected columns as atoms" do
      {controls, _changeset} = apply_attrs(%{"columns" => ["status"]})

      assert :status in ProcessListControls.attrs(controls)
    end
  end
end

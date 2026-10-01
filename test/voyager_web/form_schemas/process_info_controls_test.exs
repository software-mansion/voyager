defmodule VoyagerWeb.FormSchemas.ProcessInfoControlsTest do
  use ExUnit.Case, async: true

  alias VoyagerWeb.FormSchemas.ProcessInfoControls

  defp messages_controls do
    ProcessInfoControls.new(:messages, timeout: 5_000, budget: 5_000, limit: 50)
  end

  describe "apply/2" do
    test "accepts values inside the bounds" do
      {controls, changeset} =
        ProcessInfoControls.apply(messages_controls(), %{
          "timeout" => "2000",
          "budget" => "200",
          "limit" => "10"
        })

      assert changeset.valid?
      assert %{timeout: 2_000, budget: 200, limit: 10} = controls
    end

    test "rejects an out-of-range value and keeps the previous one" do
      {controls, changeset} =
        ProcessInfoControls.apply(messages_controls(), %{"timeout" => "999"})

      refute changeset.valid?
      assert controls.timeout == 5_000
      assert {"must be between 1000 and 30000", _opts} = changeset.errors[:timeout]
    end

    test "keeps the valid fields of a partly invalid submission" do
      {controls, changeset} =
        ProcessInfoControls.apply(messages_controls(), %{"timeout" => "2000", "limit" => "5000"})

      refute changeset.valid?
      assert controls.timeout == 2_000
      assert controls.limit == 50
    end

    test "reports a cleared input instead of silently keeping the value" do
      {controls, changeset} = ProcessInfoControls.apply(messages_controls(), %{"timeout" => ""})

      refute changeset.valid?
      assert controls.timeout == 5_000
      assert {"can't be blank", _opts} = changeset.errors[:timeout]
    end

    test "ignores fields the section does not have" do
      controls = ProcessInfoControls.new(:state, timeout: 5_000, budget: 5_000)

      {applied, changeset} = ProcessInfoControls.apply(controls, %{"limit" => "10"})

      assert changeset.valid?
      assert is_nil(applied.limit)
    end

    test "a cleared field stays declared, so its input keeps rendering" do
      {controls, changeset} = ProcessInfoControls.apply(messages_controls(), %{"limit" => ""})

      refute changeset.valid?
      assert ProcessInfoControls.field?(controls, :limit)
      assert controls.limit == 50
    end
  end

  describe "field?/2" do
    test "reports only the fields the section was built with" do
      controls = ProcessInfoControls.new(:relations, timeout: 5_000, limit: 100)

      assert ProcessInfoControls.field?(controls, :timeout)
      assert ProcessInfoControls.field?(controls, :limit)
      refute ProcessInfoControls.field?(controls, :budget)
    end
  end

  describe "restore/2" do
    test "applies stored values and drops invalid ones without an error" do
      restored =
        ProcessInfoControls.restore(messages_controls(), %{
          "timeout" => 2_000,
          "limit" => 100_000
        })

      assert restored.timeout == 2_000
      assert restored.limit == 50
    end

    test "leaves the controls alone without stored values" do
      assert ProcessInfoControls.restore(messages_controls(), nil) == messages_controls()
    end
  end
end

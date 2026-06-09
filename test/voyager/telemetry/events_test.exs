defmodule Voyager.Telemetry.EventsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Voyager.Telemetry.Events

  describe "name_to_list/1" do
    test "translates dotted event name to atom list" do
      event = [:voyager, :test, :event]

      assert Events.name_to_list("voyager.test.event") == event
    end

    test "raises an error if atom does not exist" do
      assert_raise ArgumentError, fn ->
        Events.name_to_list("unknown-voyager-event")
      end
    end
  end
end

defmodule VoyagerWeb.Utils.RefreshIntervalTest do
  use ExUnit.Case, async: true

  alias VoyagerWeb.Utils.RefreshInterval

  @options [{"Off", "off"}, {"5s", "5000"}, {"30s", "30000"}]
  @default 5000

  describe "from_params/3" do
    test "reads an offered interval" do
      assert RefreshInterval.from_params(%{"refresh" => "30000"}, @options, @default) == 30_000
    end

    test "reads a disabled auto-refresh" do
      assert RefreshInterval.from_params(%{"refresh" => "off"}, @options, @default) == nil
    end

    test "falls back to the default when the param is missing" do
      assert RefreshInterval.from_params(%{}, @options, @default) == @default
      assert RefreshInterval.from_params(%{"apps" => "demo"}, @options, @default) == @default
    end

    test "falls back to the default for intervals that are not offered" do
      assert RefreshInterval.from_params(%{"refresh" => "1"}, @options, @default) == @default
      assert RefreshInterval.from_params(%{"refresh" => "-5000"}, @options, @default) == @default
      assert RefreshInterval.from_params(%{"refresh" => "5000ms"}, @options, @default) == @default
      assert RefreshInterval.from_params(%{"refresh" => "nope"}, @options, @default) == @default
      assert RefreshInterval.from_params(%{"refresh" => ["5000"]}, @options, @default) == @default
    end
  end

  describe "from_value/3" do
    test "reads an offered value" do
      assert RefreshInterval.from_value("30000", @options, @default) == 30_000
      assert RefreshInterval.from_value("off", @options, @default) == nil
    end

    test "falls back to the default for a value that is not offered" do
      assert RefreshInterval.from_value("1", @options, @default) == @default
      assert RefreshInterval.from_value(nil, @options, @default) == @default
    end
  end

  describe "to_param/1" do
    test "renders an interval" do
      assert RefreshInterval.to_param(5000) == "5000"
    end

    test "renders a disabled auto-refresh" do
      assert RefreshInterval.to_param(nil) == "off"
    end
  end
end

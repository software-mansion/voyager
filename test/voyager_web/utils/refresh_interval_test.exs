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

    test "refuses to switch auto-refresh off for a view that offers no Off option" do
      always_on = [{"5s", "5000"}, {"30s", "30000"}]

      assert RefreshInterval.from_params(%{"refresh" => "off"}, always_on, @default) == @default
    end
  end

  describe "put_param/4" do
    test "writes the value as the canonical param, keeping the others" do
      url = RefreshInterval.put_param("/node/demo?apps=demo_app", "30000", @options, @default)

      assert url =~ "refresh=30000"
      assert url =~ "apps=demo_app"
    end

    test "stores the default instead of a value that is not offered" do
      assert RefreshInterval.put_param("/node/demo", "1", @options, @default) ==
               "/node/demo?refresh=5000"

      assert RefreshInterval.put_param("/node/demo", nil, @options, @default) ==
               "/node/demo?refresh=5000"
    end

    test "stores the default instead of Off for a view that offers no Off option" do
      always_on = [{"5s", "5000"}, {"30s", "30000"}]

      assert RefreshInterval.put_param("/node/demo", "off", always_on, @default) ==
               "/node/demo?refresh=5000"
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

defmodule Voyager.Epmd.ClientTest do
  use ExUnit.Case, async: true

  alias Voyager.Epmd.Client

  describe "get_names/3" do
    test "returns names text from the local running EPMD" do
      # EPMD is always running during tests
      assert {:ok, text} = Client.get_names()
      assert is_binary(text)
    end

    test "returns error when connecting to a port with no EPMD" do
      assert {:error, _reason} = Client.get_names(~c"127.0.0.1", 1, 500)
    end

    test "returns error for an unreachable host" do
      # RFC 5737 TEST-NET, guaranteed non-routable
      assert {:error, _reason} = Client.get_names(~c"192.0.2.1", 4369, 200)
    end
  end
end

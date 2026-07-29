defmodule VoyagerWeb.Utils.URLTest do
  use ExUnit.Case, async: true

  alias VoyagerWeb.Utils.URL

  describe "to_relative/1" do
    test "converts absolute URL to relative URL" do
      assert URL.to_relative("http://example.com/foo?bar=baz") == "/foo?bar=baz"
    end

    test "handles URLs without query parameters" do
      assert URL.to_relative("http://example.com/foo") == "/foo"
    end

    test "falls back to the root path when the URL has none" do
      assert URL.to_relative("http://example.com?bar=baz") == "/?bar=baz"
      assert URL.to_relative("http://example.com") == "/"
    end
  end

  describe "get_query_param/2" do
    test "returns the value of an existing parameter" do
      assert URL.get_query_param("http://example.com/foo?key=value", "key") == "value"
    end

    test "returns nil when the parameter is absent" do
      assert URL.get_query_param("http://example.com/foo?key=value", "nonexistent") == nil
    end

    test "returns nil when the URL has no query string" do
      assert URL.get_query_param("http://example.com/foo", "key") == nil
    end
  end

  describe "put_query_param/3" do
    test "adds a query parameter in a URL" do
      assert URL.put_query_param("http://example.com/foo", "key", "value") ==
               "http://example.com/foo?key=value"
    end

    test "adds a query parameter to a URL with existing parameters" do
      assert URL.put_query_param("http://example.com/foo?key1=value1", "key2", "value2") ==
               "http://example.com/foo?key1=value1&key2=value2"
    end

    test "updates an existing query parameter" do
      assert URL.put_query_param("http://example.com/foo?key=old", "key", "new") ==
               "http://example.com/foo?key=new"
    end
  end

  describe "put_query_params/2" do
    test "adds multiple query parameters in a URL" do
      assert URL.put_query_params("http://example.com/foo", %{
               "key1" => "value1",
               "key2" => "value2"
             }) ==
               "http://example.com/foo?key1=value1&key2=value2"
    end

    test "updates existing query parameters in a URL" do
      assert URL.put_query_params("http://example.com/foo?key1=value1", %{
               "key2" => "value2",
               "key3" => "value3"
             }) ==
               "http://example.com/foo?key1=value1&key2=value2&key3=value3"
    end

    test "doesn't modify the URL if no parameters are provided" do
      assert URL.put_query_params("http://example.com/foo", %{}) == "http://example.com/foo"
    end
  end

  describe "drop_query_param/2" do
    test "removes a query parameter from a URL" do
      assert URL.drop_query_param("http://example.com/foo?key=value", "key") ==
               "http://example.com/foo"
    end

    test "keeps the remaining parameters" do
      assert URL.drop_query_param("http://example.com/foo?key1=value1&key2=value2", "key1") ==
               "http://example.com/foo?key2=value2"
    end

    test "doesn't modify the URL if the parameter doesn't exist" do
      assert URL.drop_query_param("http://example.com/foo?key=value", "nonexistent") ==
               "http://example.com/foo?key=value"
    end
  end

  describe "modify_query_params/2" do
    test "modifies query parameters in a URL using a function" do
      assert URL.modify_query_params("http://example.com/foo?key=value", fn params ->
               Map.put(params, "new_key", "new_value")
             end) == "http://example.com/foo?key=value&new_key=new_value"
    end

    test "drops the query string when the function empties the params" do
      assert URL.modify_query_params("http://example.com/foo?key=value", fn _ -> %{} end) ==
               "http://example.com/foo"
    end
  end
end

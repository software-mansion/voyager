defmodule Voyager.Services.McpClientsTest do
  use ExUnit.Case, async: true

  alias Voyager.Services.McpClients

  @url "http://127.0.0.1:4040/mcp"

  defp link(id), do: McpClients.apps(@url) |> Enum.find(&(&1.id == id)) |> Map.fetch!(:link)

  defp query(id), do: link(id) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  test "cursor and lm studio carry a base64 url config" do
    for id <- ["cursor", "lm_studio"] do
      assert %{"name" => "voyager", "config" => config} = query(id)
      assert config |> Base.decode64!() |> JSON.decode!() == %{"url" => @url}
    end
  end

  test "vscode carries an http server definition" do
    "vscode:mcp/install?" <> config = link("vscode")

    assert config |> URI.decode() |> JSON.decode!() == %{
             "name" => "voyager",
             "type" => "http",
             "url" => @url
           }
  end

  test "goose installs a streamable http extension" do
    assert %{"url" => @url, "type" => "streamable_http", "id" => "voyager"} = query("goose")
    refute link("goose") =~ "+"
  end

  test "kiro carries the url config" do
    assert %{"config" => config} = query("kiro")
    assert %{"url" => @url} = JSON.decode!(config)
  end
end

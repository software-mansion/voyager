defmodule VoyagerWeb.FormSchemas.ConnectionParamsTest do
  use ExUnit.Case, async: true

  alias VoyagerWeb.FormSchemas.ConnectionParams

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  test "accepts a well-formed name@host node name with a cookie" do
    cs = ConnectionParams.changeset(%{"node_name" => "my_app@127.0.0.1", "cookie" => "abc"})
    assert cs.valid?
  end

  test "requires node_name and cookie" do
    cs = ConnectionParams.changeset(%{})
    refute cs.valid?
    errors = errors_on(cs)
    assert "can't be blank" in errors.node_name
    assert "can't be blank" in errors.cookie
  end

  test "rejects node_name without @" do
    cs = ConnectionParams.changeset(%{"node_name" => "no_at_sign", "cookie" => "c"})
    refute cs.valid?
    assert "Use the name@host format" in errors_on(cs).node_name
  end

  test "rejects node_name with whitespace" do
    cs = ConnectionParams.changeset(%{"node_name" => "bad name@host", "cookie" => "c"})
    refute cs.valid?
    assert "Use the name@host format" in errors_on(cs).node_name
  end

  test "rejects node_name longer than 255 chars" do
    cs =
      ConnectionParams.changeset(%{
        "node_name" => String.duplicate("a", 251) <> "@host",
        "cookie" => "c"
      })

    refute cs.valid?
    assert Enum.any?(errors_on(cs).node_name, &String.contains?(&1, "should be at most 255"))
  end

  test "rejects cookie longer than 255 chars" do
    cs =
      ConnectionParams.changeset(%{
        "node_name" => "a@h",
        "cookie" => String.duplicate("c", 256)
      })

    refute cs.valid?
    assert Enum.any?(errors_on(cs).cookie, &String.contains?(&1, "should be at most 255"))
  end

  test "defaults name_type to :longnames" do
    cs = ConnectionParams.changeset(%{"node_name" => "a@h", "cookie" => "c"})
    assert Ecto.Changeset.get_field(cs, :name_type) == :longnames
  end

  test "accepts :shortnames name_type" do
    cs =
      ConnectionParams.changeset(%{
        "node_name" => "a@h",
        "cookie" => "c",
        "name_type" => "shortnames"
      })

    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :name_type) == :shortnames
  end
end

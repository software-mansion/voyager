defmodule VoyagerWeb.LayoutsTest do
  use VoyagerWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:voyager, :dev_build?)
    on_exit(fn -> Application.put_env(:voyager, :dev_build?, previous) end)
  end

  test "root layout shows the dev banner only on a dev build", %{conn: conn} do
    Application.put_env(:voyager, :dev_build?, true)
    assert banner_count(conn) == 1

    Application.put_env(:voyager, :dev_build?, false)
    assert banner_count(conn) == 0
  end

  defp banner_count(conn) do
    conn
    |> get("/")
    |> html_response(200)
    |> LazyHTML.from_document()
    |> LazyHTML.query_by_id("dev-build-banner")
    |> Enum.count()
  end
end

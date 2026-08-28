defmodule VoyagerWeb.LayoutsTest do
  use VoyagerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias VoyagerWeb.Layouts

  setup do
    previous = Application.get_env(:voyager, :dev_build?)
    on_exit(fn -> Application.put_env(:voyager, :dev_build?, previous) end)
    :ok
  end

  describe "dev_banner/1" do
    test "renders nothing on a released build" do
      Application.put_env(:voyager, :dev_build?, false)

      assert render_component(&Layouts.dev_banner/1) =~ ~r/\A\s*\z/
    end

    test "names the build on a local build" do
      Application.put_env(:voyager, :dev_build?, true)

      html = render_component(&Layouts.dev_banner/1)

      assert html |> LazyHTML.from_fragment() |> banner_count() == 1
      assert html =~ "Dev Build"
    end
  end

  describe "root layout" do
    test "tops the page with the banner on a local build", %{conn: conn} do
      Application.put_env(:voyager, :dev_build?, true)

      assert conn |> render_page() |> banner_count() == 1
    end

    test "leaves the page unmarked on a released build", %{conn: conn} do
      Application.put_env(:voyager, :dev_build?, false)

      assert conn |> render_page() |> banner_count() == 0
    end
  end

  defp render_page(conn) do
    conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()
  end

  defp banner_count(document) do
    document |> LazyHTML.query_by_id("dev-build-banner") |> Enum.count()
  end
end

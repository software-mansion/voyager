defmodule VoyagerWeb.Router do
  use VoyagerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {VoyagerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", VoyagerWeb do
    pipe_through :browser

    live_session :connect, layout: {VoyagerWeb.Layouts, :connect} do
      live "/", ConnectLive, :index
    end

    live_session :settings, layout: {VoyagerWeb.Layouts, :settings} do
      live "/settings", SettingsLive, :index
    end

    live_session :app,
      layout: {VoyagerWeb.Layouts, :app},
      on_mount: [{VoyagerWeb.Hooks.NodeSessionHook, :require_connected_node}] do
      live "/node/:node", NodeInfoLive, :index
      live "/node/:node/supervision-tree", SupervisionTreeLive, :index
    end
  end

  if Application.compile_env(:voyager, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: Voyager.Telemetry.Metrics
    end
  end
end

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

    live_session :connect,
      layout: {VoyagerWeb.Layouts, :connect},
      on_mount: [
        {VoyagerWeb.Hooks.NodeSessionHook, :observe_node_session},
        VoyagerWeb.Hooks.OnboardingHook
      ] do
      live "/", ConnectLive, :index
    end

    live_session :settings,
      layout: {VoyagerWeb.Layouts, :settings},
      on_mount: VoyagerWeb.Hooks.McpStatusHook do
      live "/settings", SettingsLive, :index
    end

    live_session :app,
      layout: {VoyagerWeb.Layouts, :app},
      on_mount: [
        {VoyagerWeb.Hooks.NodeSessionHook, :require_connected_node},
        VoyagerWeb.Hooks.PidFormatHook,
        VoyagerWeb.Hooks.OnboardingHook,
        VoyagerWeb.Hooks.McpStatusHook
      ] do
      live "/node/:node", NodeInfoLive, :index
      live "/node/:node/supervision-tree", SupervisionTreeLive, :index

      live "/node/:node/processes", ComingSoon.ProcessesLive, :index
      live "/node/:node/ets-tables", ComingSoon.EtsTablesLive, :index
      live "/node/:node/tracing", ComingSoon.TracingLive, :index
      live "/node/:node/sockets", ComingSoon.SocketsLive, :index
      live "/node/:node/ports", ComingSoon.PortsLive, :index
      live "/node/:node/charts", ComingSoon.ChartsLive, :index
      live "/node/:node/memory-allocators", ComingSoon.MemoryAllocatorsLive, :index
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

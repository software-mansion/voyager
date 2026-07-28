defmodule VoyagerWeb do
  @moduledoc false

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]
      import Plug.Conn
      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView
      on_mount VoyagerWeb.Hooks.FlashHook
      import VoyagerWeb.Helpers
      unquote(html_helpers())

      # Default no-op so `patch` navigation (e.g. the sidebar width toggle) works
      # on every LiveView. Views that need to react to params override this.
      @impl Phoenix.LiveView
      def handle_params(_params, _uri, socket), do: {:noreply, socket}

      defoverridable handle_params: 3
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent
      import VoyagerWeb.Helpers
      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import Phoenix.Controller, only: [get_csrf_token: 0, view_module: 1, view_template: 1]
      unquote(html_helpers())
    end
  end

  def component do
    quote do
      use Phoenix.Component
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import VoyagerWeb.CoreComponents
      alias Phoenix.LiveView.JS
      alias VoyagerWeb.Layouts
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: VoyagerWeb.Endpoint,
        router: VoyagerWeb.Router,
        statics: VoyagerWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end

defmodule VoyagerWeb.SettingsLive do
  use VoyagerWeb, :live_view

  alias Voyager.NodeSession
  alias VoyagerWeb.SettingsLive.AppearanceSettings
  alias VoyagerWeb.SettingsLive.DistributionSettings
  alias VoyagerWeb.SettingsLive.McpSettings
  alias VoyagerWeb.SettingsLive.PidFormatSettings
  alias VoyagerWeb.SettingsLive.TelemetrySettings

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())
    end

    socket
    |> assign(:return_to, safe_return_to(params["return_to"]))
    |> assign(:connected?, not is_nil(NodeSession.current()))
    |> assign(:terms_of_service_url, Application.get_env(:voyager, :terms_of_service_url))
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto flex w-full max-w-2xl flex-col gap-6 px-6 py-10">
      <div>
        <h1 class="text-base-content text-2xl font-semibold tracking-tight">Settings</h1>
        <p class="text-base-content/70 mt-1 text-sm">
          Configure Voyager's appearance and distribution.
        </p>
      </div>

      <AppearanceSettings.appearance_settings />
      <.live_component module={PidFormatSettings} id="pid-format-settings" />
      <.live_component
        module={DistributionSettings}
        id="distribution-settings"
        connected?={@connected?}
      />
      <.live_component module={McpSettings} id="mcp-settings" status={@mcp_status} />
      <.live_component
        module={TelemetrySettings}
        id="telemetry-settings"
        terms_of_service_url={@terms_of_service_url}
      />
    </div>
    """
  end

  @impl true
  def handle_info({:node_connected, _node}, socket) do
    socket
    |> assign(:connected?, not is_nil(NodeSession.current()))
    |> noreply()
  end

  def handle_info({event, _node}, socket) when event in [:node_disconnected, :nodedown] do
    socket
    |> assign(:connected?, false)
    |> noreply()
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp safe_return_to(path) when is_binary(path) do
    case URI.parse(path) do
      %URI{scheme: nil, host: nil, path: "/" <> _ = route_path} ->
        if Phoenix.Router.route_info(VoyagerWeb.Router, "GET", route_path, "") == :error do
          "/"
        else
          path
        end

      _ ->
        "/"
    end
  end

  defp safe_return_to(_), do: "/"
end

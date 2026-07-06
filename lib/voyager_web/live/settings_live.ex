defmodule VoyagerWeb.SettingsLive do
  use VoyagerWeb, :live_view

  alias Voyager.MCP
  alias Voyager.NodeSession
  alias VoyagerWeb.SettingsLive.AppearanceSettings
  alias VoyagerWeb.SettingsLive.DistributionSettings
  alias VoyagerWeb.SettingsLive.McpSettings

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())
      Phoenix.PubSub.subscribe(Voyager.PubSub, MCP.topic())
    end

    socket
    |> assign(:return_to, safe_return_to(params["return_to"]))
    |> assign(:connected?, not is_nil(NodeSession.current()))
    |> assign(:mcp_status, MCP.info())
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto flex w-full max-w-2xl flex-col gap-6 px-6 py-10">
      <div>
        <h1 class="text-base-content text-2xl font-semibold tracking-tight">Settings</h1>
        <p class="text-base-content/60 mt-1 text-sm">
          Configure Voyager's appearance and distribution.
        </p>
      </div>

      <AppearanceSettings.appearance_settings />
      <.live_component
        module={DistributionSettings}
        id="distribution-settings"
        connected?={@connected?}
      />
      <.live_component module={McpSettings} id="mcp-settings" status={@mcp_status} />
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

  def handle_info({:mcp_status, status}, socket) do
    socket
    |> assign(:mcp_status, status)
    |> noreply()
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp safe_return_to(path) when is_binary(path) do
    case URI.parse(path) do
      %URI{scheme: nil, host: nil, path: "/" <> rest} ->
        if String.starts_with?(rest, "/") or String.starts_with?(rest, "\\") do
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

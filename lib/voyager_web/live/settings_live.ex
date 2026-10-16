defmodule VoyagerWeb.SettingsLive do
  use VoyagerWeb, :live_view

  alias Voyager.NodeSession
  alias Voyager.Pid
  alias Voyager.Settings
  alias VoyagerWeb.SettingsComponents
  alias VoyagerWeb.SettingsLive.AppearanceSettings
  alias VoyagerWeb.SettingsLive.DistributionSettings
  alias VoyagerWeb.SettingsLive.McpSettings
  alias VoyagerWeb.SettingsLive.TelemetrySettings
  alias VoyagerWeb.SettingsLive.UpdateSettings

  @pid_formats [
    {:distribution, "icon-network", "Distribution", "<123.23.423>",
     "Keeps the remote node index, which is used when making RPC calls."},
    {:local, "icon-laptop", "Local", "<0.23.423>",
     "Replaces the node index with 0, so you can use it on remote shells."}
  ]

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())
    end

    socket
    |> assign(:return_to, safe_return_to(params["return_to"]))
    |> assign(:connected?, not is_nil(NodeSession.current()))
    |> assign(:terms_of_service_url, Application.get_env(:voyager, :terms_of_service_url))
    |> assign(:pid_format, Pid.cached_format())
    |> ok()
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :pid_formats, @pid_formats)

    ~H"""
    <div class="mx-auto flex w-full max-w-2xl flex-col gap-6 px-6 py-10">
      <div>
        <h1 class="text-base-content text-2xl font-semibold tracking-tight">Settings</h1>
        <p class="text-base-content/70 mt-1 text-sm">
          Configure Voyager's appearance and distribution.
        </p>
      </div>

      <AppearanceSettings.appearance_settings />
      <SettingsComponents.choice_setting
        id="pid-format"
        title="PID format"
        description="Choose how process identifiers are shown in the Voyager UI."
        options={@pid_formats}
        selected={@pid_format}
        locked?={Settings.locked?(:pid_format)}
        on_select="select-pid-format"
      />
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
      <UpdateSettings.update_settings :if={@app_update_supported?} update={@app_update} />
    </div>
    """
  end

  @impl true
  def handle_event("select-pid-format", %{"choice" => choice}, socket)
      when choice in ~w(distribution local) do
    save_choice(socket, :pid_format, String.to_existing_atom(choice), &Pid.put_format/1)
  end

  @impl true
  def handle_info({:node_connected, _node}, socket) do
    socket
    |> assign(:connected?, not is_nil(NodeSession.current()))
    |> noreply()
  end

  def handle_info({event, _node, _reason}, socket)
      when event in [:node_disconnected, :nodedown] do
    socket
    |> assign(:connected?, false)
    |> noreply()
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp save_choice(socket, key, choice, cache) do
    with false <- Settings.locked?(key) or socket.assigns[key] == choice,
         {:ok, _setting} <- Settings.put(key, choice) do
      cache.(choice)

      socket
      |> assign(key, choice)
      |> noreply()
    else
      true -> {:noreply, socket}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to save the setting")}
    end
  end

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

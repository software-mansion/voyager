defmodule VoyagerWeb.SettingsLive do
  use VoyagerWeb, :live_view

  alias Voyager.NodeSession
  alias Voyager.Pid
  alias Voyager.Services.McpAgents
  alias Voyager.Services.TermSyntax
  alias VoyagerWeb.SettingsComponents
  alias VoyagerWeb.SettingsLive.AppearanceSettings
  alias VoyagerWeb.SettingsLive.DemoSettings
  alias VoyagerWeb.SettingsLive.DistributionSettings
  alias VoyagerWeb.SettingsLive.McpSettings
  alias VoyagerWeb.SettingsLive.TelemetrySettings
  alias VoyagerWeb.SettingsLive.TracingSettings
  alias VoyagerWeb.SettingsLive.UpdateSettings

  @pid_formats [
    {:distribution, "icon-network", "Distribution", "<123.23.423>",
     "Keeps the remote node index, which is used when making RPC calls."},
    {:local, "icon-laptop", "Local", "<0.23.423>",
     "Replaces the node index with 0, so you can use it on remote shells."}
  ]

  @term_syntaxes [
    {:auto, nil, "Auto", nil,
     "Erlang for nodes without the Elixir application, Elixir otherwise."},
    {:elixir, nil, "Elixir", ~S|%{name: "voyager"}|, "Shows values as Elixir terms."},
    {:erlang, nil, "Erlang", ~S|#{name => <<"voyager">>}|, "Shows values as Erlang terms."}
  ]

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: McpAgents.refresh()

    socket
    |> assign(:session, NodeSession.current())
    |> assign(:terms_of_service_url, Application.get_env(:voyager, :terms_of_service_url))
    |> assign(:pid_format, Pid.get_setting())
    |> assign(:term_syntax, TermSyntax.get_setting())
    |> assign(:focus_storage_limit?, params["focus"] == "trace_storage_limit_mb")
    |> ok()
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, pid_formats: @pid_formats, term_syntaxes: @term_syntaxes)

    ~H"""
    <div class="mx-auto w-full px-6 py-10 md:w-4/5">
      <div class="mb-6 flex items-center gap-2">
        <.back_arrow id="settings-back" href={if(!@can_go_back?, do: ~p"/")} />
        <h1 class="text-base-content text-2xl font-semibold tracking-tight">Settings</h1>
      </div>

      <div class="grid grid-cols-3 gap-6 max-2xl:grid-cols-2 max-lg:grid-cols-1">
        <div class="flex flex-col gap-6">
          <AppearanceSettings.appearance_settings />
          <DemoSettings.demo_settings session={@session} running?={@demo_running?} />
          <SettingsComponents.choice_setting
            id="pid-format"
            title="PID format"
            description="Choose how process identifiers are shown in the Voyager UI."
            options={@pid_formats}
            selected={@pid_format}
            locked?={Pid.setting_locked?()}
            on_select="select-pid-format"
          />
          <SettingsComponents.choice_setting
            id="term-syntax"
            title="Term syntax"
            description="Choose the language syntax values are shown in."
            options={@term_syntaxes}
            selected={@term_syntax}
            locked?={TermSyntax.setting_locked?()}
            on_select="select-term-syntax"
          />
        </div>
        <div class="flex flex-col gap-6">
          <.live_component module={McpSettings} id="mcp-server" agents={@mcp_agents} />
        </div>
        <div class="flex flex-col gap-6">
          <.live_component
            module={DistributionSettings}
            id="distribution-settings"
            connected?={@session != nil}
          />
          <.live_component
            module={TracingSettings}
            id="tracing-settings"
            focus?={@focus_storage_limit?}
          />
          <.live_component
            module={TelemetrySettings}
            id="telemetry-settings"
            terms_of_service_url={@terms_of_service_url}
          />
          <UpdateSettings.update_settings :if={@app_update_supported?} update={@app_update} />
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("select-pid-format", %{"choice" => choice}, socket) do
    save_choice(socket, :pid_format, Pid.save_setting(choice))
  end

  def handle_event("select-term-syntax", %{"choice" => choice}, socket) do
    save_choice(socket, :term_syntax, TermSyntax.save_setting(choice))
  end

  @impl true
  def handle_info({:node_connected, _node}, socket) do
    socket
    |> assign(:session, NodeSession.current())
    |> noreply()
  end

  def handle_info({event, _node, _reason}, socket)
      when event in [:node_disconnected, :nodedown] do
    socket
    |> assign(:session, nil)
    |> noreply()
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp save_choice(socket, key, result) do
    case result do
      {:ok, choice} ->
        socket
        |> assign(key, choice)
        |> noreply()

      {:error, %Ecto.Changeset{}} ->
        socket
        |> put_flash(:error, "Failed to save the setting")
        |> noreply()

      {:error, _unsupported_or_locked} ->
        {:noreply, socket}
    end
  end
end

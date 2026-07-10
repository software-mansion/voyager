defmodule VoyagerWeb.ConnectLive do
  use VoyagerWeb, :live_view

  alias Voyager.NodeSession
  alias VoyagerWeb.ConnectComponents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Voyager.PubSub, NodeSession.topic())
    end

    socket
    |> assign(:show_distribution_settings?, false)
    |> assign(:connected_session, NodeSession.current())
    |> assign(:mode, :direct)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-base-200 h-full overflow-y-auto">
      <div class="flex min-h-full items-center justify-center p-4">
        <div class="card bg-base-100 w-full max-w-lg shadow-xl">
          <div class="card-body gap-0 p-10">
            <div class="mb-7 flex items-center gap-3">
              <.logo />
              <div class="text-base-content text-lg font-semibold tracking-tight">Voyager</div>
              <button
                type="button"
                id="open-distribution-settings"
                phx-click="open_distribution_settings"
                title="Distribution settings"
                class="btn btn-ghost btn-square btn-sm text-base-content/50 ml-auto hover:text-base-content"
              >
                <.icon name="icon-settings" class="size-4" />
              </button>
            </div>
            <div class="mb-6">
              <h1 class="text-base-content text-2xl font-semibold tracking-tight">
                Connect to a node
              </h1>
              <p :if={@mode == :direct} class="text-base-content/60 mt-1 text-sm">
                Enter the node name and Erlang cookie to inspect a local BEAM.
              </p>
              <p :if={@mode == :ssh} class="text-base-content/60 mt-1 text-sm">
                Connect to a remote node through an SSH tunnel.
              </p>
            </div>
            <ConnectComponents.connected_indicator session={@connected_session} />
            <ConnectComponents.mode_toggle mode={@mode} disabled={not is_nil(@connected_session)} />

            <.live_component
              :if={@mode == :direct}
              module={VoyagerWeb.ConnectLive.DirectConnect}
              id="direct-connect"
              connected?={not is_nil(@connected_session)}
            />

            <.live_component
              :if={@mode == :ssh}
              module={VoyagerWeb.ConnectLive.SshConnect}
              id="ssh-connect"
              connected?={not is_nil(@connected_session)}
            />
          </div>
        </div>

        <.live_component
          :if={@show_distribution_settings?}
          module={VoyagerWeb.ConnectLive.DistributionSettings}
          id="distribution-settings-modal"
          connected?={not is_nil(@connected_session)}
        />
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("switch_mode", %{"mode" => "direct"}, socket) do
    {:noreply, assign(socket, :mode, :direct)}
  end

  def handle_event("switch_mode", %{"mode" => "ssh"}, socket) do
    {:noreply, assign(socket, :mode, :ssh)}
  end

  def handle_event("open_distribution_settings", _, socket) do
    {:noreply, assign(socket, :show_distribution_settings?, true)}
  end

  @impl true
  def handle_info({:node_connected, _node}, socket) do
    {:noreply, assign(socket, :connected_session, NodeSession.current())}
  end

  def handle_info({event, _node}, socket) when event in [:node_disconnected, :nodedown] do
    {:noreply, assign(socket, :connected_session, nil)}
  end

  def handle_info({:distribution_settings, :saved}, socket) do
    socket
    |> put_flash(:info, "Distribution suffix saved")
    |> assign(:show_distribution_settings?, false)
    |> noreply()
  end

  def handle_info({:distribution_settings, :closed}, socket) do
    socket
    |> assign(:show_distribution_settings?, false)
    |> noreply()
  end

  def handle_info({:distribution_settings, :locked}, socket) do
    socket
    |> put_flash(:error, "Distribution suffix is controlled by application config")
    |> noreply()
  end

  def handle_info(_, socket), do: {:noreply, socket}
end

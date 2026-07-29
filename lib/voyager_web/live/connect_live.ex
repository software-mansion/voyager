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
    |> assign(:connected_session, NodeSession.current())
    |> assign(:mode, :direct)
    |> assign(:connecting?, false)
    |> ok()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-base-200 h-full overflow-y-auto">
      <div class="min-w-96 flex min-h-full items-center justify-center p-4">
        <div class="card bg-base-100 w-full max-w-lg shadow-xl">
          <div class="card-body gap-0 p-10">
            <div class="mb-7 flex items-center gap-3">
              <.logo />
              <div class="text-base-content text-lg font-semibold tracking-tight">Voyager</div>
              <.link
                id="open-settings"
                href={~p"/settings?#{[return_to: "/"]}"}
                title="Settings"
                class="btn btn-ghost btn-square btn-sm text-base-content/50 ml-auto hover:text-base-content"
              >
                <.icon name="icon-settings" class="size-4" />
              </.link>
            </div>
            <ConnectComponents.connected_indicator session={@connected_session} />

            <div class="mb-6">
              <h1 class="text-base-content mb-4 text-2xl font-semibold tracking-tight">
                Connect to a node
              </h1>
              <h4 class="font-mono tracking-label text-base-content/60 mb-2 text-xs uppercase">
                Connection type:
              </h4>
              <ConnectComponents.mode_toggle
                mode={@mode}
                disabled={not is_nil(@connected_session) or @connecting?}
              />
              <p :if={@mode == :direct} class="text-base-content/60 mt-1 text-lg">
                Connect directly over Erlang distribution.
              </p>
              <p :if={@mode == :ssh} class="text-base-content/60 mt-1 text-lg">
                Connect to a remote node through an SSH tunnel.
              </p>
            </div>

            <div class={@mode != :direct && "hidden"}>
              <.live_component
                module={VoyagerWeb.ConnectLive.DirectConnect}
                id="direct-connect"
                connected?={not is_nil(@connected_session)}
              />
            </div>

            <div class={@mode != :ssh && "hidden"}>
              <.live_component
                module={VoyagerWeb.ConnectLive.SshConnect}
                id="ssh-connect"
                connected?={not is_nil(@connected_session)}
              />
            </div>
          </div>
        </div>
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

  @impl true
  def handle_info({:node_connected, _node}, socket) do
    {:noreply, assign(socket, :connected_session, NodeSession.current())}
  end

  def handle_info({event, _node}, socket) when event in [:node_disconnected, :nodedown] do
    {:noreply, assign(socket, :connected_session, nil)}
  end

  def handle_info({:ssh_connecting, connecting?}, socket) do
    {:noreply, assign(socket, :connecting?, connecting?)}
  end

  def handle_info(_, socket), do: {:noreply, socket}
end
